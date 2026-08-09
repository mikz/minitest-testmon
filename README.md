# minitest-testmon

[![CI](https://github.com/mikz/minitest-testmon/actions/workflows/ci.yml/badge.svg)](https://github.com/mikz/minitest-testmon/actions/workflows/ci.yml)

`minitest-testmon` records which inputs each Minitest test uses, then runs only
the tests affected by a change. It is conservative: uncertain startup evidence
selects every currently discovered test. Incompleteness found later preserves
the accepted per-test snapshots and retries the affected selected tests.

The gem targets MRI Ruby 4.0 and Minitest 6. Rails 8.1 works out of the
box, including Rails' native process-parallel test runner.

## Install

```ruby
# Gemfile
group :test do
  gem "minitest-testmon",
    git: "https://github.com/mikz/minitest-testmon.git",
    branch: "main"
end
```

```sh
bundle install
```

Keep the generated `bin/rails` unchanged. Bundler conventionally autorequires
the lightweight `minitest-testmon` entrypoint. In a requested Rails test run,
its Railtie verifies that Rails is preparing a complete test suite
and activates Testmon from `before_configuration`. This loads custom providers
in time to observe reads from the application class body. Rails 8.1 providers
are finalized later, after application initialization, when Rails' effective
paths are available.

A normal `bin/rails test`, console, server, runner, or plain help command only
evaluates the lightweight entrypoint. It does not load the Minitest plugin or
Testmon core, start an observer, or touch state files. Setting only
`MINITEST_TESTMON_DB` does not activate Testmon.

No setup file is required. The SQLite database defaults to
`.minitest-testmon.sqlite3` and the configuration format to version 1. Rails
uses the canonical application root; generic commands use the wrapper's
working directory. `lib/**/*.rb` and `test/**/*.rb` are already included.

Create `.minitest-testmon.rb` only to override a default or add custom inputs.
See the [configuration template](docs/templates/minitest-testmon.rb) for the
available settings.

In Rails, `:project` is fixed to the canonical application root. A configuration
that replaces it exits 2 before tests or state access. Declare additional named
roots for inputs outside the application instead.

## Run

For Rails, enable Testmon with an environment variable:

```sh
MINITEST_TESTMON=1 bin/rails test
MINITEST_TESTMON=1 bin/rails test:all
```

`1`, `true`, `yes`, and `on` are accepted case-insensitively. `--testmon`
remains available as an equivalent command-line form.

The direct Rails interface accepts the two complete suite shapes: the default
suite (`bin/rails test`) and the full suite including system tests
(`bin/rails test:all`). Test paths, other `test:*` tasks, `--include`/`--name`,
`--exclude`, `DEFAULT_TEST`, and `DEFAULT_TEST_EXCLUDE`, plus explicit Rails
`--environment`/`-e` options, are unsupported. When Rails leaves enough information for the Railtie or Minitest
plugin to inspect, Testmon rejects the invocation with exit 2 before its
runtime, SQLite lease, run receipt, or any test body. Early boot observations
are discarded. Rails may consume, reinterpret, or reject some argument
placements earlier, so their native diagnostics and ordering are not a Testmon
API. Testmon performs its own selection after Rails has discovered the complete
suite.

Set an optional state path alongside environment activation:

```sh
MINITEST_TESTMON=1 \
  MINITEST_TESTMON_DB=tmp/testmon/state.sqlite3 \
  bin/rails test
```

With command-line activation, the equivalent form is
`bin/rails test --testmon --testmon-db=tmp/testmon/state.sqlite3`.
`--testmon-db` without either environment or command-line activation is a usage
error. For direct Rails commands, the attached `=PATH` form is supported; a
separated path can be consumed by Rails as a test path before Minitest sees it.
Repeat `--testmon` is harmless.

Plain `bin/rails test --help` stays completely inert, so it cannot advertise
Testmon's options. Use `MINITEST_TESTMON=1 bin/rails test --help` (or
`bin/rails test --testmon --help`) to load the option plugin and show them
without starting the runtime.

The first successful run stores one dependency snapshot per passing test. Each
snapshot contains the exact checksum of every input learned for that test. A
later run with no relevant change executes no tests. Exit 0 means the selected
tests passed and the evidence was accepted; exit 1 is the native Minitest
failure status; exit 2 is invalid CLI usage; wrapper exit 3 means another
process holds the cache lease; and exit 4 means Testmon evidence or
infrastructure was incomplete. Direct plugin activation reports lease
contention as exit 4. To inspect why a path selects tests:

```sh
bundle exec minitest-testmon explain app/views/accounts/show.html.erb
bundle exec minitest-testmon report
bundle exec minitest-testmon runs
```

If the database path is overridden, pass the same `--database PATH` to
`report`, `runs`, and `explain`.

The wrapper supports generic Minitest commands, including their native filters,
and the two canonical Rails suite commands:

```sh
bundle exec minitest-testmon run -- bundle exec rake test
bundle exec minitest-testmon run -- bin/rails test
bundle exec minitest-testmon run --full -- bin/rails test
```

For generic commands, Minitest's native filters define the currently discovered
runnables and Testmon selects within that list. `run --full` forces all of those
currently discovered runnables; it does not broaden the child command's filter.
Use an unfiltered complete suite with `--full` when validating a provider. Rails
continues to accept only its two canonical complete-suite shapes. Publication
requires an exact execution ledger, passing non-skipped tests, complete provider
evidence, and an unchanged inventory. Rejection preserves the accepted snapshot
revision.

For Rails, early-boot wrapper support intentionally recognizes only the
project's actual `bin/rails` with exactly `test` or `test:all`. Testmon derives
the canonical application root from that launcher, resolves default
configuration and state there, runs the child from that root, and lets Bundler
plus the Railtie activate observers at `before_configuration`. Other command
shapes are rejected with exit 2 before spawn when either the configured project
or a child-command token identifies a Rails application. The generic preload
path is for non-Rails projects only. A successful child that produces no
completed run receipt fails closed with exit 4.

The wrapper rejects inherited `DEFAULT_TEST` and `DEFAULT_TEST_EXCLUDE` before
spawn. The child plugin repeats that check after Rails boot so configuration or
application code cannot turn a verified full-suite command into a partial run.

SQLite stores the current per-test snapshots and deterministic retained run
receipts in `.minitest-testmon.sqlite3`. Read the latest receipt with
`minitest-testmon report`; JSON is an output format, not a second state file.
The latest 10 run reports are retained by default. Set
`config.retained_reports N` to choose a different positive limit.

A skipped test gets retry state and is selected on every run until it passes.
Its previous accepted snapshot, if any, is retained. A test failure rejects the
whole publication atomically: snapshots from passing tests in the same run do
not replace the last accepted state.

## Rails 8.1

Activated Rails applications automatically get versioned providers for boot
inputs, schema files, views, locales, fixtures, and Propshaft assets when
available. Rails process workers are supported, including an explicit
`parallelize_me!` when Rails process parallelization is active. Thread-backed
Minitest parallel tests and Rails thread parallelization are rejected before
tests start because per-test evidence would be ambiguous.

```ruby
# Opt out of all automatic Rails 8.1 providers.
Minitest::Testmon.configure do |config|
  config.disable_bundle :rails_8_1
end
```

See [Rails support](docs/rails.md) for provider IDs and parallel-worker failure
semantics.

## Custom inputs

Ruby execution is only part of a test's dependency graph. Templates, YAML,
generated manifests, framework lookup paths, and application-specific loaders
belong in providers. A provider declares the files that can matter, observes a
public runtime signal, and claims matching content for the current test. Every
declared inventory also has one automatic suite-scoped membership checksum, so
additions, deletions, and renames conservatively select all discovered tests.

```ruby
Minitest::Testmon.configure do |config|
  config.provider :application_settings, version: 1 do
    # See docs/providers.md for a complete, copyable provider.
  end
end
```

The public entry point is exactly:

```ruby
config.provider(name, implementation = nil, version:, &block)
```

See [custom providers](docs/providers.md) for YAML content and membership,
TracePoint loader, and notification examples. See
[provider validation](docs/discovery.md) for the validation workflow.

## Coverage and SimpleCov

The runner uses Ruby's `Coverage` primitive as execution evidence; it does not
use SimpleCov as a dependency. If SimpleCov is active, testmon reads coverage
non-destructively and does not stop, clear, or restart it. SimpleCov remains the
owner of reporting and thresholds.

Rubydex is deliberately not on the selection path. It is a static semantic
index, while sound test selection needs runtime evidence for metaprogramming,
autoloading, framework notifications, file contents, and lookup membership.
Adding a second source graph would not replace those observations.

See [Coverage and SimpleCov](docs/coverage-and-simplecov.md) for the full
rationale and load-order guidance.

## Design constraints

- No monkeypatching of `File`, `IO`, `Kernel`, Minitest, Rails, or I18n.
- Paths are stored as logical `root:relative/path` identities, not machine-local
  absolute paths.
- Provider/configuration versions participate in the context signature.
- Ruby source inputs use SHA-256 of exact bytes; ISeq is only an MRI TracePoint
  capability probe, not a persisted checksum.
- Gem, fingerprint-algorithm, selection-algorithm, MRI, and compile-option
  versions participate in the context signature.
- Every inventory is rebuilt after observers close. Content, membership,
  existence, symlink, and canonical-path drift blocks publication.
- SQLite is parent-owned. Rails workers write durable spools which the parent
  validates and merges once.
- Missing, ambiguous, or malformed evidence fails open to more tests, never to
  fewer tests.
- Selection is one ordered list with reasons. There are no `all`, `subset`, or
  `none` execution modes.

## Documentation

- [Custom providers](docs/providers.md)
- [Discovery and validation](docs/discovery.md)
- [Rails 8.1](docs/rails.md)
- [Coverage, SimpleCov, and Rubydex](docs/coverage-and-simplecov.md)
