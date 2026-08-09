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
`app/**/*.rb` to Ruby inventory and activates five core providers plus the
optional asset provider when Propshaft is loaded:

The configuration may add named roots for external inputs, but it may not
replace `:project`. Both the direct Railtie and wrapper require that root to
remain exactly the canonical Rails application root and exit 2 before state
access if it changes.

| Provider | Inputs | Scope |
| --- | --- | --- |
| `rails.boot@1` | `config/**/*.rb` and top-level `config/*.{yml,yaml}` | suite |
| `rails.schema@1` | schema/structure files and migrations | suite |
| `rails.views@1` | template content per test; view-path membership copied to every test | mixed |
| `rails.locales@1` | locale content per consumer; load-path membership copied to every test | mixed |
| `rails.fixtures@1` | declared fixture content per test; fixture membership copied to every test | mixed |
| `rails.assets@1` | resolved content per test; asset membership copied to every test | mixed |

Boot and schema content is suite-scoped because changing it can alter the
environment in which every test runs. Views, locales, fixtures, and resolved
assets claim existing-file content against tests that use public Rails/I18n
signals. As with every provider inventory, their path membership is
suite-scoped: additions, deletions, and renames select every discovered test.

`rails.assets@1` activates only when Propshaft is loaded. Every asset
resolution funnels through `Propshaft::LoadPath#find`, so a test that resolves
an asset URL — a system test loading a page, or any test rendering
`stylesheet_link_tag` — claims that asset's content. Build inputs that cannot
be tied to one logical path (importmap, `package.json`, lockfiles, bundler
configs, `app/javascript` sources) are claimed conservatively by every
asset-resolving test, the same way locale lookups claim every locale file. When
a configured Propshaft asset root contains one of those conventional build
input directories (or is contained by it), the precise asset inventory owns
the overlapping tree; Testmon does not declare it again as a coarse input.

Nested application data such as `config/policies/**/*.yml` is intentionally not
claimed by `rails.boot@1`. Give it an application provider so edits to existing
files can select exact consumers; inventory membership remains suite-scoped.

Run the ordinary Rails command:

```sh
MINITEST_TESTMON=1 bin/rails test
MINITEST_TESTMON=1 bin/rails test:all
```

`1`, `true`, `yes`, and `on` enable Testmon case-insensitively. The
`--testmon` flag remains an equivalent command-line form.

This direct interface is deliberately complete-suite only. Two suite shapes
qualify: the default suite (`bin/rails test`, which excludes `test/system`)
and the full suite (`bin/rails test:all`). Rails runs `test:all` as the same
single Minitest execution whose only difference is the `test/**/*_test.rb`
file list; Testmon recognizes exactly that canonical shape. Test paths, other
`test:*` tasks, `--include`/`--name`, `--exclude`, `DEFAULT_TEST`, and
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

The wrapper supports the exact complete-suite Rails command:

```sh
bundle exec minitest-testmon run -- bin/rails test
bundle exec minitest-testmon run -- bin/rails test:all
bundle exec minitest-testmon run --full -- bin/rails test:all
```

`run` selects the affected tests; a cold cache selects every discovered test.
`run --full` adds every discovered test with reason `forced` on a warm cache.

The launcher must be the project's actual `bin/rails` and `test` or `test:all`
must be its only argument. Testmon derives the application root from that launcher before
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
individually in the run report so a provider version change invalidates
the context explicitly.

## Views, locales, and fixtures

Each supported file family has two kinds of artifact:

- A **content** facet detects an edit to an existing file.
- A **membership** facet detects additions, removals, renames, and lookup-order
  changes.

This distinction matters for optional template lookup: a missing template has
no content to hash, but adding it can change behavior. Testmon does not assume a
successful render signal observes every failed or shadowed lookup, so membership
is copied into every passing test snapshot. The same conservative rule applies
to locale, fixture, and asset inventories.

At every `ActiveSupport::TestCase` boundary, the fixture provider reads the
public `fixture_table_names` declaration. Named declarations claim matching
content; `fixtures :all` claims all frozen fixture content. The fixture-path
membership input is already copied to every passing test. This happens in serial
and process workers, so Rails' process-local fixture cache does not determine
ownership.

Direct `ActiveRecord::FixtureSet.create_fixtures` calls remain a fallback for
explicit/manual loads and claim their named content for the current test.
Framework cache calls with no fixture names are ignored. Include every
legitimate fixture directory in Rails' `fixture_paths` so it is declared before
selection; an undeclared or racing path is incomplete evidence and fails open.

## System tests and `bin/rails test:all`

System tests are ordinary Minitest runnables in the same Minitest invocation and
dependency store; `test:all` differs from `test` only in its file list. They keep the ordinary failure,
skip, and dirty-test semantics, and Rails process parallelization applies to
them unchanged.

`test` and `test:all` share one dependency store safely. Selection is per test:
each test records the fingerprints of its inputs as of its own last accepted run,
so a `test` run never touches system-test snapshots. Running `test` and then
`test:all` therefore runs only system tests that have no snapshot. If a
suite-scoped input changes, the default-suite tests update their copies only
after they pass; system tests retain the old checksum and are still selected by
the later `test:all`. See [the design note](design/per-test-dependency-snapshots.md).

Attribution inside a system test relies on an explicit operating assumption:

- Capybara teardown normally drains its in-process server requests inside the
  Minitest run boundary before Testmon's coverage snapshot. The test server
  must be isolated from unrelated inbound requests; attribution cannot
  distinguish such a request from one initiated by the sole active system test.
- Testmon prepends a request-attribution Rack middleware in activated test
  runs. Server threads (Capybara boots Puma in-process) carry no thread-local
  test id; the middleware stamps the request thread with the sole active test
  for the duration of the request, so app code, template renders,
  translations, and asset resolutions triggered by a page load are claimed by
  the visiting test rather than left unattributed.

The stamp is strictly per-request and borrows the boundary's revocable
attribution token. Child threads created by the request inherit that same
token. A child still alive when the test finishes is `thread_leak`; revocation
prevents its later work from being attached to another test. Project Ruby on a
pre-existing pool with no token is `ambiguous_context` while a boundary is
active. Both conditions make the run incomplete, as does a true late observer
activation. Overlapping boundaries (thread-parallel tests) remain rejected.

JavaScript executed in the browser is invisible to Ruby coverage; the
`rails.assets@1` provider covers the served files instead. An edit to an asset
selects the tests that resolved it, and build-input changes (importmap,
lockfiles, `app/javascript`) select every asset-resolving test conservatively.

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
signature, revision, duplicate results, and the exact selected/executed
ledger, then merges all worker evidence and publishes once. After a complete
run is validated and imported, the parent removes exactly that run's UUID
directory. Incomplete or unvalidated directories remain available for
conservative recovery. Cleanup derives the workers directory from the canonical
project root and refuses to recurse through a symlinked `tmp`,
`minitest-testmon`, workers, or UUID directory.

A missing, malformed, duplicate, or unsealed worker spool yields
`publication.reason: "worker_incomplete"`. The prior accepted snapshot revision
is retained;
the direct command exits 4, and the next run recovers conservatively. Failure
to remove a validated run uses the same fail-closed reason and cannot publish a
new revision. Suite-scoped observations remain diagnostic; their current inputs
are copied into each passing test snapshot by the parent snapshot builder.

Rails thread parallelization and native Minitest `parallelize_me!` are rejected
before any test executes:

```ruby
parallelize(workers: 4, with: :threads) # unsupported
parallelize_me!                          # unsupported
```

The command reports `unsupported_parallelism` and mentions `Rails process
parallelization`. It does not change the previous snapshot revision or
inventory.
Per-test `Coverage` deltas and process-global notifications cannot be assigned
soundly when test bodies overlap in threads.

## Skips

A skipped test has no new snapshot. Its prior accepted snapshot, if any, remains
unchanged, and retry state selects the test again on every run until it passes.
Skipped tests do not invalidate complete evidence from other passing tests.

Any assertion failure is different: it rejects publication for the whole run.
No passing snapshot from that run replaces durable state, the failed test stays
dirty, and the last accepted revision remains authoritative.

## Rails validation matrix

Before enabling the runner in CI, validate:

- workers `1`, `2`, and `4` produce equivalent inventory and per-test inputs;
- `bin/rails test:all` learns, certifies warm, and re-runs system tests only
  when their inputs change;
- an asset edit selects exactly the tests that resolved it;
- a template edit selects its renderer;
- template add/delete/rename selects every discovered test conservatively;
- a locale edit selects translation consumers;
- declared and manually loaded fixture edits select their consumers;
- boot or schema edits select every currently discovered test;
- a killed worker retains the prior snapshot revision and recovers on the next run;
- SimpleCov works when required before or after the testmon preload;
- workers hold no descriptor for `.minitest-testmon.sqlite3`.

See [discovery](discovery.md) for the generic validation gate.
