# minitest-testmon

[![CI](https://github.com/mikz/minitest-testmon/actions/workflows/ci.yml/badge.svg)](https://github.com/mikz/minitest-testmon/actions/workflows/ci.yml)

`minitest-testmon` records which inputs each Minitest test uses, then runs only
the tests affected by a change. It is conservative: incomplete evidence causes
a full run, and an incomplete or failed run never replaces the last good
dependency graph.

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
its Railtie verifies that Rails is preparing the complete default test suite
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
```

`1`, `true`, `yes`, and `on` are accepted case-insensitively. `--testmon`
remains available as an equivalent command-line form.

The direct Rails interface accepts only the complete default suite. Test paths,
`test:*` tasks, `--include`/`--name`, `--exclude`, `DEFAULT_TEST`, and
`DEFAULT_TEST_EXCLUDE`, plus explicit Rails `--environment`/`-e` options, are
unsupported. When Rails leaves enough information for the Railtie or Minitest
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

The first successful run builds the graph. A later run with no relevant change
executes no tests. Exit 0 means the selected tests passed and the evidence was
accepted; exit 1 is the native Minitest failure status; exit 2 is invalid CLI
usage; exit 4 means Testmon evidence or infrastructure was incomplete. To
inspect why a path selects tests:

```sh
bundle exec minitest-testmon explain app/views/accounts/show.html.erb
bundle exec minitest-testmon report
bundle exec minitest-testmon runs
```

If the database path is overridden, pass the same `--database PATH` to
`report`, `runs`, and `explain`.

The wrapper remains available for non-Rails commands and explicit Rails
discovery or selection:

```sh
bundle exec minitest-testmon run -- bundle exec rake test
bundle exec minitest-testmon discover -- bin/rails test
bundle exec minitest-testmon run -- bin/rails test
```

The command after `--` must also discover the complete suite. `discover`
publishes only when the full discovered suite executes exactly once, every
non-skipped test passes, every provider is complete, and the provider inventory
is unchanged from start to finish. Otherwise it exits nonzero and retains the
last good generation.

For Rails, early-boot wrapper support intentionally recognizes only the
project's actual `bin/rails` with exactly the `test` argument. Testmon derives
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

SQLite stores the active graph, retained graph generations, and deterministic
run receipts in `.minitest-testmon.sqlite3`. Read the latest receipt with
`minitest-testmon report`; JSON is an output format, not a second state file.
The latest 10 run reports are retained by default. Set
`config.retained_reports N` to choose a different positive limit.

An already-skipped test is treated as a permanent dirty test: it publishes with
no dependency edges and is selected on every run. An unchanged skip-only retry
certifies the existing generation instead of rewriting it. If a test that
previously passed or owned edges starts skipping, Testmon retains the old graph
and requires one full recovery run before accepting it as a permanent skip.
Failures retain their established fail-closed behavior.

## Rails 8.1

Activated Rails applications automatically get versioned providers for boot
inputs, schema files, views, locales, and fixtures. Native process workers are
supported; Rails thread parallelization is rejected before tests start because
per-test evidence would be ambiguous.

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
public runtime signal, and claims the matching content and membership facets
for the current test.

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
TracePoint loader, and notification examples. See [discovery](docs/discovery.md)
for the validation workflow.

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
- Gem, fingerprint-algorithm, selection-algorithm, MRI, and compile-option
  versions participate in the context signature.
- Every inventory is rebuilt after observers close. Content, membership,
  existence, symlink, and canonical-path drift blocks publication.
- SQLite is parent-owned. Rails workers write durable spools which the parent
  validates and merges once.
- Missing, ambiguous, or malformed evidence fails open to more tests, never to
  fewer tests.

## Documentation

- [Custom providers](docs/providers.md)
- [Discovery and validation](docs/discovery.md)
- [Rails 8.1](docs/rails.md)
- [Coverage, SimpleCov, and Rubydex](docs/coverage-and-simplecov.md)
