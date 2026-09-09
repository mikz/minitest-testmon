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

`1`, `true`, `yes`, and `on` are accepted case-insensitively. Native Rails
commands also support focused suites, files, line ranges, names, and exclusions:

```sh
MINITEST_TESTMON=1 bin/rails test test/models/widget_test.rb
MINITEST_TESTMON=1 bin/rails test --name test_widget
MINITEST_TESTMON=1 bin/rails db:test:prepare test:system
```

Testmon selects affected tests within the requested subset and preserves cached
snapshots for omitted tests. A focused receipt does not certify the whole suite.
Use environment activation for focused runs: Rails can parse command-line flags
before loading the gem. `--testmon` remains available for commands that load the
application before option parsing. See [Rails integration](docs/rails.md).

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
later run with no relevant change executes no tests. Tests run once, and their
normal result remains authoritative. If Testmon cannot safely update its cache,
it keeps the last known-good state and prints a warning. Invalid or unsupported
commands still fail clearly. To inspect why a path selects tests:

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

Existing Minitest filters still apply. `run --full` runs every test included by
the command, but it does not remove those filters. Use an unfiltered complete
suite with `--full` when validating a provider. Testmon saves validated passing
tests in checkpoints during the run. A later
failure or interruption preserves those checkpoints. Failed, skipped, and
unverified tests run again. Saved tests are skipped only when their recorded
inputs still match.

Checkpoints run at result boundaries after 25 passing tests or five seconds,
and once more at normal completion. If files change during a run, Testmon stops
learning for that run and preserves earlier checkpoints. Pending results are
not saved. You can keep editing without losing progress already accepted.

For Rails, use the project's own `bin/rails` with exactly `test` or `test:all`.
Other command shapes are rejected before tests start. If Testmon cannot safely
learn from a successful run, it keeps the last known-good cache and prints a
warning.

The wrapper rejects `DEFAULT_TEST` and `DEFAULT_TEST_EXCLUDE`; use the native
Rails interface with Testmon enabled for focused runs.

The console reports cached, selected, checkpointed, retained, and retry counts.
Report schema 3 adds `checkpoints` with `count`, `accepted_ids`, and `stop_reason`.
A partial cache does not certify that the whole suite passed. Providers that
require end-of-run finalization keep final-only publication.

SQLite stores the current per-test snapshots and deterministic retained run
receipts in `.minitest-testmon.sqlite3`. Read the latest receipt with
`minitest-testmon report`; JSON is an output format, not a second state file.
The latest 10 run reports are retained by default. Set
`config.retained_reports N` to choose a different positive limit.

A skipped test gets retry state and is selected on every run until it passes.
Its previous accepted snapshot, if any, is retained. Failed tests also keep retry
state. Validated passing tests from the same run can still be checkpointed.

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
