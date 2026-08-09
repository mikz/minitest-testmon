# minitest-testmon black-box acceptance

This directory is an independent acceptance harness for the public
`minitest-testmon` contract. It does not load files from the gem's `lib/`
directory by path and does not inspect its SQLite schema. The harness reaches
the product only through:

- the `minitest-testmon` executable;
- `require "minitest/testmon"`;
- `Minitest::Testmon.configure`;
- `.minitest-testmon.rb`;
- `.minitest-testmon.sqlite3`;
- `minitest-testmon report`.

Run the harness from the repository root:

```sh
bundle exec rake test:acceptance
```

The harness uses Minitest's standard parallel scheduling with Rails' process
executor. `PARALLEL_WORKERS` controls the process count through the normal Rails
convention; no acceptance-specific sharding is used.

The harness defaults to the repository's `exe/minitest-testmon`. Override it
without changing the fixtures:

```sh
MINITEST_TESTMON_BIN='bundle exec minitest-testmon' \
  bundle exec rake test:acceptance
```

When the executable is absent, harness self-tests run and product acceptance
tests report an explicit skip. `REQUIRE_MINITEST_TESTMON=1` turns absence into
a failure for CI promotion gates.

All product runs happen in disposable copies of the golden fixtures. Source
fixtures are never mutated.

## Rails 8.1 gate

The Rails acceptance fixture requires Ruby 4, Rails 8.1, PostgreSQL
access through the `pg` gem, and SimpleCov. It creates uniquely named
disposable test databases, including Rails' native per-worker databases, and
drops them after each case. It never uses an application database.
The fixture sets `PGGSSENCMODE=disable` only in its child environment to avoid
pg/libpq GSS state inherited across `fork` on the supported Ruby 4 runtime;
this is not product configuration.

The Rails matrix treats process parallelization, including process-backed
`parallelize_me!`, as supported and thread parallelization as an explicit
pre-test rejection. It also rejects an explicit parallel test when Rails process
parallelization is inactive, before Rails can discard the queued test. The
matrix compares workers 1, 2, and 4; exercises the five auto-activated Rails
provider bundles; mutates view content and membership, locales, declared and
manually loaded fixtures, boot inputs, and schema inputs; kills a worker; checks
both SimpleCov load orders; and observes worker file descriptors with `lsof`
when available.

The direct Rails CLI matrix carries an exact stock `bin/rails` in the fake
application. The fixture conventionally autorequires its test-group gems with
`Bundler.require(*Rails.groups)`. Canonical activation is
`bin/rails test --testmon`; the database path is normally supplied by
environment, while attached `--testmon-db=PATH` remains covered explicitly.
Plain test/help commands
must stay inert, and native partial path/name failures must not create state.
The matrix also invokes
`minitest-testmon discover|run -- /absolute/app/bin/rails test` from outside
the app and requires configuration, default state, and process cwd to resolve
to the app root. A project config that tries to replace the canonical Rails
`:project` root must fail before tests or state in both direct and wrapper
entry paths.

The custom provider fixture observes the first statement in the Rails
`Application` class body, proving configuration and user observers start at
the Railtie `before_configuration` boundary. Built-in Rails providers are
checked separately against view, locale, and fixture paths registered after
application initialization. Public `File`, `IO`, `YAML`/`Psych`, Minitest, and
Rails method and ancestor snapshots must remain unchanged.

## Adversarial consistency gate

The adversarial fixture adds independent black-box cases for content, membership,
and symlink changes both during a selected test and after selection but before
the dependency read. It also covers delayed background threads, selected
skips, removed failed tests, complete and incomplete discovery, provider
version invalidation, native `parallelize_me!`, suite-scoped evidence,
overlapping providers, outside-root symlink/FIFO escape, SQLite busy handling,
and report atomicity under `SIGKILL`.

Rails process workers additionally emit 20,000 duplicate provider events and
pause before test exit. The parent process must expose a non-empty JSONL spool
while the worker is still alive and remain within explicit disk and RSS bounds.
The killed-worker acceptance remains the black-box missing-result gate. A
validation oracle independently rejects duplicate and missing normalized JSONL
worker results; exact parser wiring is also a gem-unit and static-review gate,
so the public product has no acceptance-only fault-injection environment API.

To validate only the harness oracles:

```sh
bundle exec rake test:acceptance:self
```
