# Custom providers

A provider teaches testmon about an input that Ruby execution coverage cannot
describe by itself: YAML, templates, manifests, lookup paths, fixtures, or an
application-specific loader.

Every supported input follows the same model:

1. **Inventory** declares the complete candidate file set before selection.
2. **Facets** say what can change: file contents, set membership, or both.
3. **Observations and claims** connect a public runtime signal to declared
   artifacts for the current test.

If an observation cannot be claimed or intentionally ignored, the provider is
incomplete and testmon fails open. It does not invent an edge from an unknown
path.

## Registration

The public entry point is:

```ruby
config.provider(name, implementation = nil, version:, &block)
```

The block form is an instance-evaluated DSL; do not give the block a parameter.

```ruby
Minitest::Testmon.configure do |config|
  config.provider :application_settings, version: 1 do
    # inventory, facets, observers, claims, and ignores
  end
end
```

The object form is for a reusable lower-level provider implementation:

```ruby
config.provider :company_contracts, CompanyContractsProvider.new, version: 3
```

Use either an implementation object or a DSL block. Provider names are unique.
The positive integer version is part of the context signature and appears in
reports as, for example, `application_settings@1`. Bump it whenever inventory,
fingerprinting, observation, or claim semantics change.

Configured definitions are available for read-only introspection:

```ruby
Minitest::Testmon.configuration.providers
```

Configuration is Ruby only. There is no `.minitest-testmon.yml`; YAML is an
input format a provider can inventory, not a second configuration language.

## Copyable YAML provider

This provider inventories all application settings, fingerprints each file,
fingerprints the set of paths, observes `YAML.load_file`, and claims both facets
for the calling test:

```ruby
# .minitest-testmon.rb
require "yaml"

Minitest::Testmon.configure do |config|
  config.provider :application_settings, version: 1 do
    inventory :yaml,
      root: :project,
      base: "config/settings",
      include: ["**/*.yml", "**/*.yaml"],
      exclude: ["**/*.generated.yml"]

    facet :yaml_content,
      inventory: :yaml,
      digest: :content,
      granularity: :file,
      scope: :test

    facet :yaml_membership,
      inventory: :yaml,
      digest: :paths,
      granularity: :set,
      scope: :test

    observe_tracepoint :yaml_read,
      target: [YAML, :load_file],
      event: :call,
      path: ->(trace) { trace.local(:filename) },
      details: ->(trace) { {"method" => trace.method_id.to_s} }

    claim :yaml_read,
      to: [:yaml, :yaml_content],
      path: :path

    claim :yaml_read,
      to: [:yaml, :yaml_membership]
  end
end
```

Use a narrower application loader as the TracePoint target if unrelated code
also calls `YAML.load_file`. The target is `[owner_or_receiver, method_name]` or
a deferred `"Constant.method"` string.
For example, after loading an application `Settings` module whose Ruby method
is `Settings.load(path)`:

```ruby
observe_tracepoint :yaml_read,
  target: [Settings, :load],
  event: :call,
  path: ->(trace) { trace.local(:path) }
```

An edit to an existing settings file changes its `yaml_content` artifact. An
addition, deletion, or rename changes the single `yaml_membership` artifact.
Claiming both means a test which performs settings lookup is selected for either
kind of change, including the appearance of a previously missing optional file.

## Inventory

Declare an inventory once and reference it by name from one or more facets:

```ruby
inventory :templates,
  root: :project,
  base: "app/documents",
  include: ["**/*.erb"],
  exclude: ["generated/**/*"]
```

- `root` is a configured logical root.
- `base` is relative to that root.
- `include` and `exclude` are arrays of glob patterns relative to `base`.
- Results are normalized, deduplicated, and ordered before fingerprinting.
- A file outside configured roots cannot become an artifact.

Inputs outside the project can use another stable logical root:

```ruby
Minitest::Testmon.configure do |config|
  config.root :shared, "../shared"

  config.provider :shared_schemas, version: 1 do
    inventory :schemas,
      root: :shared,
      base: "schemas",
      include: ["**/*.json"],
      exclude: []

    facet :schema_content,
      inventory: :schemas,
      digest: :content,
      granularity: :file,
      scope: :test
  end
end
```

Reports store paths such as `shared:schemas/payment.json`, not absolute paths.
The root must exist when configuration is loaded.

## Facets

The public form is:

```ruby
facet name,
  inventory: inventory_name,
  digest: :content | :paths,
  granularity: :file | :set,
  scope: :test | :suite
```

Use these two combinations for ordinary custom files:

| Purpose | `digest` | `granularity` | Result |
| --- | --- | --- | --- |
| Existing-file edit | `:content` | `:file` | one artifact per file |
| Add/delete/rename | `:paths` | `:set` | one membership artifact |

`:test` scope requires a claim from a test observation. `:suite` adds a global
edge and is appropriate only when any change must run the complete suite, such
as boot configuration. Prefer test-scoped content plus membership when a public
runtime signal can identify consumers.

## Claims

Each direct claim maps an observation kind to exactly one
`[inventory_name, facet_name]` pair:

```ruby
claim :yaml_read,
  to: [:yaml, :yaml_content],
  path: :path

claim :yaml_read,
  to: [:yaml, :yaml_membership]
```

For a file-granularity facet, `path` selects the declared artifact. For a
set-granularity facet, the claim selects the inventory's set artifact. A path
which does not resolve to a declared artifact is incomplete evidence; it is not
dynamically added to the inventory.

`path:` can be `:path` or a callable receiving the immutable observation. An
advanced claim keeps the same `to:` pair and uses `using:` instead of `path:`:

```ruby
claim :contract_lookup,
  to: [:contracts, :content],
  using: ->(observation, facet_snapshot) {
    facet_snapshot.artifact_keys.select do |key|
      key.end_with?("/#{observation.details.fetch("contract")}.json")
    end
  }
```

The frozen `Minitest::Testmon::FacetSnapshot` exposes exactly `name`, `digest`,
`granularity`, `scope`, and `artifact_keys`. A custom selector may return only
keys from `artifact_keys`. Returning an undeclared key makes the provider
incomplete; returning `nil` or an empty array declines the claim.

Prefer direct claims. `using:` is for semantic lookup where a path alone cannot
choose among already declared artifacts.

## TracePoint observers

The public form is:

```ruby
observe_tracepoint observation_kind,
  target: [owner_or_receiver, method_name],
  event: tracepoint_event,
  path: path_extractor,
  details: details_extractor
```

`path` and `details` are called only for matching events. They receive a
read-only wrapper, not Ruby's raw `TracePoint`. The wrapper exposes `event`,
`method_id`, `path`, `lineno`, and `local(name)`. `path` returns the input path.
`details` returns optional canonical data used by a custom claim or discovery
diagnostics: `nil`, a JSON scalar, an array, or a hash with string keys.

Use `:call` on a Ruby loader when its argument is available through
`trace.local(:argument_name)`, as in the YAML example. A native `:c_call`
generally does not expose method arguments, so it cannot safely attribute an
arbitrary path. In that case, observe a public Ruby wrapper or a semantic
notification. Do not patch `File`, `IO`, `Kernel`, or the loader.

Core Ruby support observes `:script_compiled`, including files compiled by a
`require` or `load` after observers start. This proves compilation happened and
identifies the source path without patching the loader. It does not fire for a
require cache hit, enumerate files which never execute, or prove which YAML,
ERB, translation, or custom data the script used. The declared inventory is
still the selection-time source of truth, and non-Ruby inputs still need their
own observations and claims.

Project `:line` and `:call` events use MRI instruction-sequence targets rather
than a global Ruby-line callback. Preloaded methods/procs are targeted from the
sealed Ruby inventory; `:script_compiled` adds targets for code loaded later.
This is also the safety detector for project code running on an unattributed
thread while a test is active.

Generic C-level `File`/`IO` observations are enabled during `discover`. They
also remain enabled during a normal run whenever an active provider declares a
`file_open` or `file_read` claim, so a reexecuted test can relearn that edge.
They are not enabled merely as unused diagnostics on every normal run. Native
direct reads still do not expose their argument path; use a Ruby wrapper,
notification, or a tracked `File` instance when an exact path is required.

## Notification observers

Use a framework or application notification when it already represents the
semantic operation. This example assumes application code instruments
`render.document` with an `identifier` path and optional `virtual_path`:

```ruby
Minitest::Testmon.configure do |config|
  config.provider :documents, version: 1 do
    inventory :templates,
      root: :project,
      base: "app/documents",
      include: ["**/*.erb"],
      exclude: []

    facet :template_content,
      inventory: :templates,
      digest: :content,
      granularity: :file,
      scope: :test

    facet :template_membership,
      inventory: :templates,
      digest: :paths,
      granularity: :set,
      scope: :test

    observe_notification :document_render,
      "render.document",
      path: ->(notification) { notification.payload["identifier"] },
      details: ->(notification) {
        {"virtual_path" => notification.payload["virtual_path"]}
      }

    claim :document_render,
      to: [:templates, :template_content],
      path: :path

    claim :document_render,
      to: [:templates, :template_membership]
  end
end
```

Application code emits the matching public event normally:

```ruby
ActiveSupport::Notifications.instrument(
  "render.document",
  identifier: template_path,
  virtual_path: "invoices/show"
) do
  render_document(template_path)
end
```

The extractor receives a read-only wrapper exposing `name` and `payload`.
`payload` is a recursively frozen copy with string or symbol keys; it is not the
framework's mutable payload object. `details` has the same canonical return
constraint as a TracePoint details extractor: hashes returned by user code must
use string keys.

Notification subscribers are installed before test filtering. A subscriber
startup failure forces a full run; it cannot silently remove dependencies.

Rails' built-in providers use this same pattern for Action View events. Do not
register the example `documents` provider for ordinary Rails views—the
automatic `rails.views@1` provider already handles them.

## Intentional ignores

Ignore only an observation which is provably irrelevant or whose canonical
source is claimed elsewhere:

```ruby
ignore :document_render,
  reason: "inline preview has no filesystem input",
  predicate: ->(observation) {
    observation.path.nil? &&
      observation.details["virtual_path"].to_s.start_with?("inline:")
  }
```

The public form is:

```ruby
ignore observation_kind, reason:, predicate:
```

The predicate receives the immutable observation. Matching events remain
visible under `observations.ignored` with the stated reason. An ignore is not a
fallback for a difficult integration: if changing the ignored input could
change a test, declare and claim it instead.

## Provider lifecycle and safety

At the start of a run, testmon inventories every facet and starts every
observer **before** it computes or applies selection. At the end, it closes
observers, rebuilds every inventory and facet, resolves observations through
claims/ignores, and publishes only if the evidence, execution ledger, and
start/end inventory seal are complete. A content edit, membership change,
existence change, symlink retarget, or canonical-path change during the run
retains the prior generation and forces conservative recovery.

TracePoint also detects project Ruby executing on a thread with no test-local
ID while another test boundary is active. Such evidence is promoted to a
suite-scoped dependency with `reason: "promoted_to_suite"`; it is never attached
to whichever test happens to be active on another thread.

Provider definitions are part of the configuration snapshot. Duplicate names,
unknown inventory/facet references, invalid roots, unsupported digest or
granularity values, unknown artifact keys, observer failures, and unclaimed
observations are configuration or completeness failures. They result in a
clear error or conservative full-run behavior, never a narrower guess.

Keep extractors and custom selectors deterministic and side-effect free. They
also run inside Rails process workers, so they must use only the supplied
immutable wrappers/snapshots and fork-safe application constants. Testmon owns
worker evidence transport; a provider must not open the testmon SQLite cache.

Use [`minitest-testmon discover`](discovery.md) after adding or changing a
provider, then exercise content edits and membership add/delete/rename cases
before publishing it to CI.
