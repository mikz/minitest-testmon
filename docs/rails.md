# Rails 8.1

Use Rails' generated `bin/rails` unchanged and declare `minitest-testmon`
normally in the Gemfile's test group. Bundler autorequires a lightweight
entrypoint. For an activated Rails test command, its Railtie confirms
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
`--testmon` flag remains available when Rails loads the application before
parsing Minitest options. Use environment activation for focused paths and names.

Native Rails commands support full suites, `test:system`, other `test:*`
suites, paths, line ranges, names, and exclusions with Testmon enabled:

```sh
MINITEST_TESTMON=1 bin/rails test test/models/widget_test.rb
MINITEST_TESTMON=1 bin/rails test test/models/widget_test.rb:12
MINITEST_TESTMON=1 bin/rails test --name test_widget
MINITEST_TESTMON=1 bin/rails db:test:prepare test:system
```

Focused files must load the application's test helper. Rails skips its prepare
step for paths and names; Testmon activates when that helper loads Rails.
Selection intersects the native filters with affected tests. A focused receipt
covers only the discovered subset; it does not certify omitted tests. Cached
snapshots outside that subset stay untouched, and focused runs retain previously
learned shared inputs. Explicit Rails environment flags remain unsupported;
use the normal test environment.

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
through `MINITEST_TESTMON` or `--testmon`. Invalid or unsupported commands fail
before tests start. Once a supported run starts, the normal Minitest result
remains authoritative. If Testmon cannot safely update its cache, it keeps the
last known-good state and prints a warning.

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

Passing tests are saved during execution in checkpoints, including Rails process
workers. A later failure or interruption keeps accepted checkpoints. Testmon
checks each saved test's input fingerprints on the next run before skipping it.
If files change during execution, cache learning pauses for that run; earlier
checkpoints remain. The console reports saved progress and pending retries.

`run` selects the affected tests; a cold cache selects every discovered test.
`run --full` adds every discovered test with reason `forced` on a warm cache.

Run the command from the Rails project and use its own `bin/rails` with exactly
`test` or `test:all`. This ensures Testmon uses the correct configuration and
cache. Other command shapes are rejected before tests start. If Testmon cannot
safely learn from a successful run, it keeps the last known-good cache and
prints a warning.

The wrapper requires unfiltered `test` or `test:all` commands. Use the native
Rails interface above for focused runs, including `DEFAULT_TEST` and
`DEFAULT_TEST_EXCLUDE`, while keeping Testmon enabled.

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

View notifications may also identify layouts supplied by a loaded engine gem
whose files are outside every configured root. Those dependency-owned views are
reported as intentionally ignored rather than making publication incomplete.
An outside path that is not an existing file under a loaded gem remains
unresolved and fails closed. Add an explicit named root when shared application
views outside the project should participate in dependency checksums.

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
- Puma loads application configuration on the server-startup thread before
  handling requests. Testmon borrows the same token only while Puma loads and
  finalizes that configuration, including its mode hooks. A configuration
  operation still in flight when the test ends blocks publication.
  Configuration creates shared server state, so its observations are
  suite-scoped, not dependencies of only the first system test. This explicit
  boundary can promote a known whole-file content or Ruby-source input, such
  as `config/puma.rb` or a required boot helper, to suite scope. An
  unattributed nil-test observation cannot create new suite ownership, though
  it may reuse an existing suite-scoped whole-file owner. A set-content or
  existence-only input still fails closed instead of allowing later tests to
  use stale shared state.

- With `playwright-ruby-client`, Testmon also attributes `Page` and
  `BrowserContext` route handlers and `on`/`once` listeners for the duration of
  each callback. The browser must belong to the sole active test, and callbacks
  must finish within its boundary. Persistent registrations produce suite-scoped
  evidence. Removing a listener with `off` or a handler with `unroute` keeps the
  original callback identity. Other asynchronous APIs and unrelated background
  work remain subject to the normal attribution checks.

The stamp lasts only for the request, configuration operation, or callback and borrows
the boundary's revocable attribution token. Child threads whose block belongs
to the sealed Ruby source inventory (including project configuration)
inherit that token and evidence scope. Persistent gem-owned Puma and Playwright
service threads do not inherit it. An attributed child or borrowed request
still active when the test finishes is `thread_leak`; revocation
prevents its later work from being attached to another test. Project Ruby on a
pre-existing pool with no token is `ambiguous_context` while a boundary is
active. Both conditions make the run incomplete, as does a true late observer
activation. Overlapping boundaries (thread-parallel tests) remain rejected.

Suite scope is persisted in each passing test snapshot. During a later partial
run, Testmon retains those shared inputs only when the current
provider/configuration context still matches. This preserves a learned Puma
helper dependency even when Puma does not start in that run; a changed context
drops the carry and requires a fresh complete run to learn it again. Cache
schema changes quarantine the old database and start with a cold cache. A
complete selected run re-evaluates suite ownership from live evidence, so a
helper removed from Puma startup remains attached only to the tests that use
it directly.

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

The parent process exclusively owns the SQLite lease. It disconnects before
workers fork and reconnects to commit checkpoints. Workers never open SQLite.
Each worker streams a run-scoped JSONL spool and seals a separate, synced
completion frame before delivering each test result to the parent. The parent
validates the frame's run ID, worker identity, sequence, context, starting
revision, and outcome before accepting the test in a checkpoint.

After Rails shuts down its executor, the parent validates the complete worker
spools and selected/executed ledger for the final receipt. Earlier checkpoints
survive missing workers or an incomplete final spool. Only committed SQLite
snapshots are reused after interruption; incomplete spool fragments are not
salvaged. Run completeness and cache progress are reported separately, and
Minitest's exit status remains authoritative.

After a complete run is validated and imported, the parent removes exactly that
run's UUID directory. Incomplete directories remain for diagnosis. Cleanup
refuses to recurse through symlinked directory components. A cleanup failure
rejects final publication while preserving earlier checkpoints.

An explicit `parallelize_me!` is supported when Rails process parallelization
is active:

```ruby
class ActiveSupport::TestCase
  parallelize(workers: 4, with: :processes, threshold: 0)
end

class SomeTest < ActiveSupport::TestCase
  parallelize_me! # supported by the active Rails process executor
end
```

Thread-backed Minitest parallel tests and active non-process Rails
parallelization remain unsupported. An explicit `parallelize_me!` is also
rejected when Rails process parallelization is inactive, because Rails would
otherwise discard its queued tests. The command reports
`unsupported_parallelism` before any test executes and does not change the
previous snapshot revision or inventory. Custom executor objects are rejected
unless they follow Rails' process-executor convention.
Per-test `Coverage` deltas and process-global notifications cannot be assigned
soundly when test bodies overlap in threads.

## Skips

A skipped test has no new snapshot. Its prior accepted snapshot, if any, remains
unchanged, and retry state selects the test again on every run until it passes.
Skipped tests do not invalidate complete evidence from other passing tests.

Assertion failures retain retry state for the failed test. Other tests with
complete passing evidence can still be checkpointed.

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
