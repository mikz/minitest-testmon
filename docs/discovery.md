# Discovery and validation

Discovery is the safety check for a provider. It runs the unfiltered suite,
collects observations, builds the complete inventory and dependency edges,
and atomically publishes a baseline when the evidence is complete.

```sh
bundle exec minitest-testmon discover -- bundle exec rake test
bundle exec minitest-testmon discover -- bin/rails test
```

The command stores its receipt in `.minitest-testmon.sqlite3` and prints the
canonical JSON report to stdout. A passing, complete discovery has
`publication.published: true` and `ready: true`; the next unchanged `run`
executes only permanent skips. A failed, incomplete, or source-racing
discovery exits nonzero, remains unpublished, and preserves the last good
generation and inventory.

## Read the report

Read the latest retained receipt with `bundle exec minitest-testmon report`.
Use `minitest-testmon runs` to list retained run IDs and
`minitest-testmon report RUN_ID` for a specific receipt. Start with these
fields:

Testmon retains the latest 10 accepted graph generations and 10 run reports.
Pending, completed, and abandoned runs share this limit so interrupted runs
cannot grow the database without bound. The active leased run is retained while
it is running. Override the report limit with `config.retained_reports N`.
When `config.database` overrides the default path, pass the same path to these
commands with `--database PATH`.

- `tests.discovered`, `selected`, and `executed` show the test boundary.
- `bundles` lists exact provider IDs and versions.
- `observations.claimed` lists runtime signals connected to artifacts.
- `observations.ignored` lists signals intentionally excluded by a provider.
- `observations.uncovered` or `unresolved` means the graph is not safe to
  publish.
- `inventory.claimed` lists artifacts with dependency edges.
- `inventory.suite_scoped` lists artifacts whose change selects the full suite.
- `inventory.verified_empty` lists declared artifacts which no test used.
- `inventory.unresolved` means fingerprinting or ownership was incomplete.
- `suggestions` contains deterministic provider diagnostics.
- `publication` says whether durable state changed and why.

Paths appear as logical identities such as
`project:config/settings/payments.yml`, so reports are stable across checkout
locations.

Discovery enables generic C-level `File`/`IO` observation to expose provider
gaps. MRI does not expose direct C-call arguments, so an opaque read is reported
as unresolved rather than guessed. `:script_compiled` identifies Ruby loaded
during a test, while project line/call events are instruction-sequence-targeted
to avoid tracing framework and gem code.

## Provider validation gate

Use this gate before relying on a new or changed provider:

1. Run `discover` against the full suite.
2. Confirm every expected provider appears in `bundles` with its version.
3. Confirm representative files appear with both the intended facet and
   provider.
4. Confirm representative tests have claimed observations; explain or
   intentionally ignore every uncovered observation.
5. Confirm discovery published the baseline, then run once unchanged; no test
   should execute.
6. Change one file's contents. Only its consumers should execute.
7. For a lookup set, add, delete, and rename a file. Consumers of the
   membership artifact should execute.
8. Change a suite-scoped input. The full suite should execute.
9. Make a selected test fail, make a previously passing test skip, or kill a
   Rails worker. The generation and prior edges must stay unchanged; the
   recovery run must be conservative.
10. Confirm a new permanent skip publishes without edges and is selected on
    every run. Its unchanged skip-only retry must keep the same generation.
11. Restore the input and run twice. The first run repairs the graph; the
    second should execute no tests other than permanent skips.

The gate checks both directions: missed tests are unsound, but selecting an
unrelated test usually means the claim is too broad.

## Explain a selection

After a published run, query the durable graph without opening SQLite:

```sh
bundle exec minitest-testmon explain config/settings/payments.yml
bundle exec minitest-testmon explain PaymentsTest
```

`explain` returns the logical path, facet, fingerprint, test ID, provider, and
current generation. Pass `--generation N` to inspect a retained graph
generation. The CLI is the supported diagnostic interface; consumers do not
inspect the SQLite schema directly.

## Fail-open outcomes

The last complete generation is retained when a run has a test failure, a
passed/edge-owning test transitions to skipped, an incomplete provider,
unresolved path, source drift, malformed worker spool, killed worker, or cache
lease conflict. The next safe action is either a subset containing known-dirty
tests or a full recovery. New and already-known permanent skips are safe to
publish without edges, remain dirty, and are always selected. A report with
`publication.published: false` must never be interpreted as a new dependency
baseline.
