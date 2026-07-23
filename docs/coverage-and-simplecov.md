# Coverage, SimpleCov, and Rubydex

## Why Ruby Coverage

Test selection needs a runtime answer to a narrow question: which executable
Ruby bodies ran inside this test boundary? MRI's standard `Coverage` API is the
smallest authoritative primitive for that job. Line counters are associated
with the instruction sequences Ruby actually executed, and
`Coverage.peek_result` reads the current counters without stopping or clearing
the coverage session.

`minitest-testmon` snapshots those counters around each serial test and records
the delta. Ruby instruction-sequence fingerprints map executed lines to stable
method/class/top-level artifacts. TracePoint supplies complementary load,
method-call, file, and framework-provider observations. Coverage alone does not
detect YAML, template membership, or semantic framework lookup, which is why
those inputs use providers.

The line/call TracePoints are targeted with MRI's
`TracePoint#enable(target: iseq)` to instruction sequences from the sealed
project Ruby inventory. Testmon materializes targets for preloaded project
methods and procs, and a small process-global `:script_compiled` observer adds a
target before newly compiled project code executes. Rails and gem lines do not
enter the callback. This keeps TracePoint useful for load validation, constant
reads, and unattributed background-thread execution without making a global
line hook the main recorder.

The runner uses the standard library directly instead of adding an abstraction
layer between execution evidence and MRI. This keeps ownership and failure
semantics explicit.

Ruby reference: [`Coverage`](https://docs.ruby-lang.org/en/4.0/Coverage.html).

## Why not SimpleCov as the recorder

SimpleCov is the right application-facing tool for coverage reports, filters,
groups, minimum thresholds, formatters, and merging report results. It is not a
test-to-input dependency recorder. Using its filtered/reporting model as the
selection substrate would couple correctness to presentation configuration and
result formatting.

SimpleCov itself builds on Ruby Coverage and requires `SimpleCov.start` before
application code is loaded. Keep that normal setup:

```ruby
# test/test_helper.rb -- before requiring the application
require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
end

require_relative "../config/environment"
```

When Coverage is already running, testmon uses `Coverage.peek_result`. It does
not call `Coverage.result`, stop, clear, suspend, resume, or restart the session.
SimpleCov remains responsible for its result set and report. When SimpleCov is
absent, testmon starts line/eval Coverage for its own per-test evidence.

The testmon preload intentionally does not start Coverage. This leaves the
test helper's usual early `SimpleCov.start` in control. Do not defer SimpleCov
until after application code; that would make SimpleCov's own report
incomplete, regardless of test selection.

SimpleCov reference: [SimpleCov README](https://github.com/simplecov-ruby/simplecov#readme).

## Why not Rubydex

Rubydex is a high-performance static analysis toolkit. It indexes declarations,
documents, constant references, method references, and require paths, then
resolves a semantic workspace graph. Those capabilities are valuable for
navigation, language servers, linters, and future diagnostics.

They do not establish that a particular test used an input at runtime. Ruby and
Rails routinely add edges through metaprogramming, autoloading, dynamic method
dispatch, notification payloads, ordered view paths, I18n load paths, fixture
declarations, and arbitrary file contents. A static reference can also exist
without the path executing in a test. Treating either case as ground truth
would produce missed tests or permanently broad selections.

The KISS choice is therefore:

- MRI `Coverage` and instruction-sequence fingerprints for executed Ruby;
- targeted TracePoint for project Ruby and public loader/call boundaries where
  arguments are observable;
- framework notifications for semantic runtime events;
- declared content and membership artifacts for non-Ruby inputs;
- full-run fallback when any observation cannot be claimed safely.

Rubydex would add a native static graph, invalidation rules, and reconciliation
logic without removing any of those runtime mechanisms. It is not a dependency
for selection. It could later power optional discovery suggestions—for example,
finding likely loaders or provider gaps—but suggestions must never become
dependency edges until runtime evidence or an explicit suite-scoped declaration
confirms them.

Rubydex reference: [Rubydex documentation](https://shopify.github.io/rubydex/).

## Where Prism fits

Prism parses source; it does not observe execution. It can help derive stable
source identities, validate configuration, or improve diagnostics, but it
cannot replace Coverage, TracePoint, notifications, or membership
fingerprinting. Testmon uses Prism narrowly to recognize top-level Ruby state
writes that cannot be assigned a method identity; those files receive an
explicit whole-file fallback. MRI instruction sequences remain the
runtime-aligned structural fingerprint for methods and nested blocks.
