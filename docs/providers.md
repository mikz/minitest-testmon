# Custom providers

A provider teaches testmon about an input that Ruby execution coverage cannot
describe by itself: YAML, templates, manifests, lookup paths, fixtures, or an
application-specific loader.

Every supported input follows the same model:

1. **Inventory** declares the complete candidate file set before selection.
2. **Facets** say what can change. Every inventory automatically gets one
   suite-scoped path-membership facet; providers usually add file-content facets.
3. **Observations and claims** connect a public runtime signal to declared
   artifacts for the current test.

If Testmon cannot determine an input safely, it does not guess. The test result
is preserved, Testmon prints a warning, and the last known-good cache remains in
use.

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
observes `YAML.load_file`, and claims the matching content for the calling test.
The builder adds the inventory's suite-scoped membership checksum automatically:

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

    observe_tracepoint :yaml_read,
      target: [YAML, :load_file],
      event: :call,
      path: ->(trace) { trace.local(:filename) },
      details: ->(trace) { {"method" => trace.method_id.to_s} }

    claim :yaml_read,
      to: [:yaml, :yaml_content],
      path: :path
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

An edit to an existing settings file changes its `yaml_content` input and selects
the tests that loaded it. An addition, deletion, or rename changes the automatic
membership input and conservatively selects every discovered test. Testmon does
not infer from a successful loader call that the same signal observes failed
lookups or future shadowing files.

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
  digest: :content | :existence | :paths | :contents,
  granularity: :file | :set,
  scope: :test | :suite
```

Use `content/file` for ordinary custom files. `existence/file` tracks whether a
declared path exists. `contents/set` provides one coarse checksum for the set's
paths and contents. `paths/set` is reserved for the single membership facet
that Testmon adds or normalizes for each inventory. The internal
`ruby_source/file` facet is reserved for Testmon's Ruby provider.

| Purpose | `digest` | `granularity` | Result |
| --- | --- | --- | --- |
| Existing-file edit | `:content` | `:file` | one artifact per file |
| Existence change | `:existence` | `:file` | one artifact per declared path |
| Add/delete/rename | `:paths` | `:set` | one suite-scoped membership input |
| Coarse set content | `:contents` | `:set` | one suite-scoped set input |

`:test` scope requires a claim from a test observation. `:suite` copies the input
into every passing test snapshot, so a later change selects every discovered test
that has learned it. Membership is always normalized to `:suite`, even if a
provider declares `scope: :test`; a claim alone cannot prove complete observation
of additions, misses, or lookup shadowing.

The `config.fileset` convenience API is deliberately coarse and always
suite-scoped. Use a provider with observations and claims for per-test content
attribution.

## Claims

Each direct claim maps an observation kind to exactly one
`[inventory_name, facet_name]` pair:

```ruby
claim :yaml_read,
  to: [:yaml, :yaml_content],
  path: :path

# No membership claim is needed; it is suite-scoped automatically.
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

Project `:line`, `:call`, and `:b_call` events use MRI instruction-sequence
targets rather than a global Ruby-line callback. Preloaded methods/procs are
targeted from the sealed Ruby inventory; `:script_compiled` adds targets for
code loaded later. A preloaded C-backed method with project source, such as an
`attr_accessor`, is indexed by its exact owner and method name and attributed
from `:c_call` to that source. This is also the safety detector for project code
running on an unattributed thread while a test is active.

Generic C-level `File`/`IO` observations are enabled by `run --full`. They also
remain enabled during a normal run whenever an active
provider declares a `file_open` or `file_read` claim, so a reexecuted test can
relearn that edge. They are not enabled merely as unused diagnostics on every
normal run. Native
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

    observe_notification :document_render,
      "render.document",
      path: ->(notification) { notification.payload["identifier"] },
      details: ->(notification) {
        {"virtual_path" => notification.payload["virtual_path"]}
      }

    claim :document_render,
      to: [:templates, :template_content],
      path: :path
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

Notification subscribers are installed before Testmon applies its selected-ID
filter. A subscriber startup failure selects every discovered test and blocks
publication; it cannot silently remove dependencies.

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
retains the prior revision and leaves selected tests in retry state.

Testmon propagates a revocable attribution token through `Thread.new`,
`Thread.start`, and `Thread.fork` when the block's canonical source path belongs
to the sealed Ruby inventory. Joined project child-thread work is claimed by
the test that created it; persistent gem-owned service threads stay unbound.
Finishing the test revokes that token; a still-live attributed child
marks the run incomplete as `thread_leak` and can no longer claim later work.
Project Ruby executed by a pre-existing pool with no token while a boundary is
active is `ambiguous_context` and also blocks publication. A true observer
late-start failure remains `late_activation` and blocks publication.

Server configuration uses suite-scoped evidence while borrowing a test token
for lifetime tracking. Its owned child threads inherit that scope. Inputs
without a safe whole-file identity fail closed in this scope rather than
assigning shared startup state to whichever test first starts the server. An
observation recorded under that explicit suite boundary may promote a known
whole-file content or Ruby-source artifact. An unattributed nil-test
observation cannot create new suite ownership, but it may reuse an existing
suite-scoped whole-file input with the same canonical path and fingerprint.
Published suite scope is stored with each test snapshot and carried through a
later partial run only when the current provider/configuration context still
matches, so a server that does not start cannot erase a learned shared
dependency. A schema mismatch quarantines the old cache and starts cold. None
of these paths ignore explicit attribution failures. A complete selected run
re-evaluates suite ownership from live evidence, so a helper removed from shared
startup is not retained as a suite dependency.

Provider definitions are part of the configuration snapshot. Duplicate names,
unknown inventory/facet references, invalid roots, unsupported digest or
granularity values, unknown artifact keys, observer failures, and unclaimed
observations are configuration or completeness failures. They result in a
clear error or selection of every discovered test, never a narrower guess.

Keep extractors and custom selectors deterministic and side-effect free. They
also run inside Rails process workers, so they must use only the supplied
immutable wrappers/snapshots and fork-safe application constants. Testmon owns
worker evidence transport; a provider must not open the testmon SQLite cache.

Use [`minitest-testmon run --full`](discovery.md) after adding or changing a
provider, then exercise content edits and membership add/delete/rename cases
before publishing it to CI.
