# Rails 8.1

Use Rails' generated `bin/rails` unchanged and declare `minitest-testmon`
normally in the Gemfile's test group. Bundler autorequires a lightweight
entrypoint. For an activated complete Rails test command, its Railtie confirms
the `test:prepare` lifecycle and starts Testmon from
`before_configuration`, using `Rails::Command.application_root` as the
canonical root. No application initializer is required.

`.minitest-testmon.rb` and its custom observers are therefore active before the
application class body continues, so they can observe application and
framework inputs read during boot. The built-in Rails bundle is finalized only
from the Minitest plugin after application initialization, when configured
view, locale, fixture, and schema paths are authoritative. Testmon adds
`app/**/*.rb` to Ruby inventory and activates five providers:

The configuration may add named roots for external inputs, but it may not
replace `:project`. Both the direct Railtie and wrapper require that root to
remain exactly the canonical Rails application root and exit 2 before state
access if it changes.

| Provider | Inputs | Scope |
| --- | --- | --- |
| `rails.boot@1` | `config/**/*.rb` and top-level `config/*.{yml,yaml}` | suite |
| `rails.schema@1` | schema/structure files and migrations | suite |
| `rails.views@1` | ordered view paths, template content, lookup membership | test |
| `rails.locales@1` | ordered `I18n.load_path` membership and locale content | test |
| `rails.fixtures@1` | declared fixture content/membership and explicit fixture loads | test |

Boot and schema artifacts are suite-scoped because changing them can alter the
environment in which every test runs. Views, locales, and fixtures are claimed
against the tests that use their public Rails/I18n signals.

Nested application data such as `config/policies/**/*.yml` is intentionally not
claimed by `rails.boot@1`. Give it an application provider so content and
membership changes can select exact consumers instead of the full suite.

Run the ordinary Rails command:

```sh
MINITEST_TESTMON=1 bin/rails test
```

`1`, `true`, `yes`, and `on` enable Testmon case-insensitively. The
`--testmon` flag remains an equivalent command-line form.

This direct interface is deliberately full-suite only. Test paths, `test:*`
tasks, `--include`/`--name`, `--exclude`, `DEFAULT_TEST`, and
`DEFAULT_TEST_EXCLUDE`, plus explicit Rails environment options, are
unsupported. When the relevant state remains visible after Rails parsing,
Testmon exits 2 before a test body, runtime store, or evidence write and
discards any early observations. A `test:*` task can still pass through Rails'
own `test:prepare` and application boot before the Minitest plugin can reject
it; `test:prepare` itself can fail natively before the application exists.
Similarly, Rails may consume or reject path, name, and environment argument
placements before Testmon sees them. Those native diagnostics and their
ordering are outside the Testmon contract.

Set an optional state path in the environment:

```sh
MINITEST_TESTMON=true \
  MINITEST_TESTMON_DB=tmp/testmon/state.sqlite3 \
  bin/rails test
```

With command-line activation, the equivalent form is
`bin/rails test --testmon --testmon-db=tmp/testmon/state.sqlite3`. The
separated `--testmon-db PATH` form is not supported for direct Rails commands
because Rails can treat `PATH` as a test path. The option requires activation
through `MINITEST_TESTMON` or `--testmon`. Invalid configuration also exits 2;
incomplete evidence, an unavailable observer, a worker protocol failure, or
cache contention exits 4. Ordinary Minitest failures keep exit 1.

Plain `bin/rails test --help` is intentionally inert and cannot advertise
Testmon. `MINITEST_TESTMON=1 bin/rails test --help` (or
`bin/rails test --testmon --help`) loads only enough to show the Minitest
options and creates no state.

The wrapper supports the exact complete-suite Rails command for discovery and
selection:

```sh
bundle exec minitest-testmon discover -- bin/rails test
bundle exec minitest-testmon run -- bin/rails test
```

The launcher must be the project's actual `bin/rails` and `test` must be its
only argument. Testmon derives the application root from that launcher before
loading `.minitest-testmon.rb`, resolves default state paths under that root,
and spawns Rails with that working directory. It deliberately omits the generic
`RUBYOPT` plugin preload so Bundler and the Railtie own early activation; this
keeps custom TracePoint targets defined by configuration visible before the
application body runs. Other command shapes are rejected with exit 2 before
spawn when the configured root or a child token identifies a Rails application;
generic wrapper preloading is reserved for non-Rails projects. A zero-exit
child without a fresh valid Testmon report makes the wrapper exit 4.

Inherited `DEFAULT_TEST` and `DEFAULT_TEST_EXCLUDE` are rejected before wrapper
spawn. The Rails child checks them again after boot, covering changes made by
configuration or application code before Minitest initialization.

To disable the complete automatic bundle:

```ruby
# .minitest-testmon.rb
Minitest::Testmon.configure do |config|
  config.disable_bundle :rails_8_1
end
```

`rails_8_1` is only the opt-out name; it is not a provider ID. Providers appear
individually in the discovery report so a provider version change invalidates
the context explicitly.

## Views, locales, and fixtures

Each supported file family has two kinds of artifact:

- A **content** facet detects an edit to an existing file.
- A **membership** facet detects additions, removals, renames, and lookup-order
  changes.

This distinction matters for optional template lookup: a missing template has
no content to hash, but adding it can change behavior. The view membership edge
selects the lookup consumer. The same rule applies to locale and fixture load
paths.

At every `ActiveSupport::TestCase` boundary, the fixture provider reads the
public `fixture_table_names` declaration. Named declarations claim matching
content plus the frozen fixture-path membership; `fixtures :all` claims all
frozen fixture content. This happens for every test in serial and process
workers, so Rails' process-local fixture cache cannot attach directory
membership to whichever test happens to run first.

Direct `ActiveRecord::FixtureSet.create_fixtures` calls remain a fallback for
explicit/manual loads and claim their named content for the current test.
Framework cache calls with no fixture names are ignored. Include every
legitimate fixture directory in Rails' `fixture_paths` so it is declared before
selection; an undeclared or racing path is incomplete evidence and fails open.

## Native parallel tests

Rails process parallelization is supported:

```ruby
class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors, with: :processes)
end
```

The parent process exclusively owns the SQLite lease. It disconnects before a
fork; workers never open SQLite. Each worker streams a run-scoped JSONL spool
without retaining the event stream in memory or fsyncing each record. At the
terminal record it flushes, fsyncs, and atomically seals the spool. After Rails
shuts down its executor, the parent verifies run ID, worker identity, context
signature, generation, duplicate results, and the exact selected/executed
ledger, then merges all worker evidence and publishes once. After a complete
run is validated and imported, the parent removes exactly that run's UUID
directory. Incomplete or unvalidated directories remain available for
conservative recovery. Cleanup derives the workers directory from the canonical
project root and refuses to recurse through a symlinked `tmp`,
`minitest-testmon`, workers, or UUID directory.

A missing, malformed, duplicate, or unsealed worker spool yields
`publication.reason: "worker_incomplete"`. The prior generation is retained;
the direct command exits 4, and the next run recovers conservatively. Failure
to remove a validated run uses the same fail-closed reason and cannot publish a
new generation. Suite-scoped artifacts discard per-test IDs when worker
evidence is merged; those IDs are semantically irrelevant once a `*` edge
exists and would otherwise make reports depend on worker scheduling.

Rails thread parallelization and native Minitest `parallelize_me!` are rejected
before any test executes:

```ruby
parallelize(workers: 4, with: :threads) # unsupported
parallelize_me!                          # unsupported
```

The command reports `unsupported_parallelism` and mentions `Rails process
parallelization`. It does not change the previous generation or inventory.
Per-test `Coverage` deltas and process-global notifications cannot be assigned
soundly when test bodies overlap in threads.

## Skips

A test that is already skipped in the first complete run is stored as a
permanent dirty test with no dependency edges and is selected every time. A
skip-only warm run with unchanged inputs certifies the same generation. Known
permanent skips do not block valid evidence from other selected passing tests.

If a previously passing or edge-owning test starts skipping, the run is
rejected with `publication.reason: "test_skip"` and the prior graph is retained.
The next run is forced full. If that full recovery confirms the skip, Testmon
removes its old edges and accepts it as permanent; if it passes, its ordinary
edges are relearned. Test failures remain dirty and retain the existing
failure-selection behavior.

## Rails validation matrix

Before enabling the runner in CI, validate:

- workers `1`, `2`, and `4` produce equivalent inventory and dependency edges;
- a template edit selects its renderer;
- template add/delete/rename selects lookup consumers;
- a locale edit selects translation consumers;
- declared and manually loaded fixture edits select their consumers;
- boot or schema edits select the full suite;
- a killed worker retains the prior generation and recovers on the next run;
- SimpleCov works when required before or after the testmon preload;
- workers hold no descriptor for `.minitest-testmon.sqlite3`.

See [discovery](discovery.md) for the generic validation gate.
