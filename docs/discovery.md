# Provider validation

There is no separate discovery mode. Every run learns the tests it executes.
Use `run --full` with an unfiltered complete-suite command to select every
currently discovered Minitest runnable when validating a new or changed
provider:

```sh
bundle exec minitest-testmon run --full -- bundle exec rake test
bundle exec minitest-testmon run --full -- bin/rails test
```

Minitest first loads tests and applies its native options through
`filter_runnable_methods`. Testmon snapshots current inputs and starts observers,
then computes one exact selected-ID list and applies that list back to Minitest.
A cold cache also selects every discovered test because none has a snapshot.

The command stores its receipt in `.minitest-testmon.sqlite3` and prints the
canonical JSON report. A passing, complete run has
`publication.published: true` and `ready: true`; the next unchanged run executes
only tests carrying retry state. A failed, incomplete, or source-racing run
preserves the last accepted snapshots.

## Read the report

Read the latest retained receipt with `bundle exec minitest-testmon report`.
Use `minitest-testmon runs` to list retained run IDs and
`minitest-testmon report RUN_ID` for a specific receipt. The latest 10 receipts
are retained by default; configure `config.retained_reports N` to change that
positive limit. With a non-default database, pass the same `--database PATH` to
`report`, `runs`, and `explain`.

Important fields are:

- `complete` says whether the run's evidence was safe to publish;
- `diagnostics` lists run-level completeness failure codes; item-level details
  remain on entries under `observations` and `inventory`;
- `tests.discovered`, `selected`, and `executed` show the exact ledger;
- `bundles` lists provider IDs and versions;
- `observations.claimed` connects runtime signals to inputs;
- `observations.ignored` records intentional exclusions;
- `observations.uncovered` or `unresolved` means evidence was not safe;
- `inventory.claimed` lists test-attributed inputs;
- `inventory.suite_scoped` lists inputs copied into every passing snapshot;
- `inventory.verified_empty` lists declared inputs not claimed by a test;
- `inventory.unresolved` means fingerprinting or ownership was incomplete;
- `publication` says whether durable snapshots changed and why.

Paths use logical identities such as `project:config/settings/payments.yml`, not
checkout-specific absolute paths.

## Validation gate

Before relying on a provider:

1. Run `run --full` against the complete suite.
2. Confirm the provider and version in `bundles`.
3. Confirm representative files have the intended facet and provider.
4. Confirm representative tests claim their existing-file content.
5. Explain or intentionally ignore every uncovered observation.
6. Confirm publication, then run unchanged; no passing test should execute.
7. Edit one existing file; only tests claiming its content should execute.
8. Add, delete, and rename an inventory member; every discovered test should
   execute because membership is suite-scoped.
9. Change another suite-scoped input; every discovered test should execute.
10. Make one selected test fail. The entire publication must be rejected and all
    prior snapshots must remain unchanged.
11. Kill a Rails worker. The worker run must remain unpublished and recover
    conservatively.
12. Restore the input and run twice. The first run repairs selected snapshots;
    the second should execute no passing tests.

The gate checks both safety and usefulness. A missed test is unsound. An extra
test after an existing-file edit usually means a content claim is too broad;
extra tests after membership change are the deliberate conservative contract.

## Explain a selection

After an accepted run, query snapshots without opening SQLite directly:

```sh
bundle exec minitest-testmon explain config/settings/payments.yml
bundle exec minitest-testmon explain PaymentsTest
```

`explain` returns logical path, facet, checksum, test ID, provider, and current
revision. The SQLite schema is described for design review, but the CLI remains
the supported diagnostic interface.

## Fail-open outcomes

Accepted checkpoints survive later test failures, source drift, and interruption.
Tests with retry state are selected again; saved tests are compared against
current input fingerprints before being skipped. Source drift stops further
learning for that run. Incomplete provider evidence or worker frames cannot
become checkpoints. Contradictory outcomes revoke the implicated checkpoint.

Startup incompleteness expands selection to all discovered tests. Incompleteness
found after selection cannot retroactively execute omitted tests. A report with
`publication.published: false` does not certify a successful suite, even when its
`checkpoints` field records accepted progress. `minitest-testmon runs` also shows
checkpoint progress for running and abandoned runs.
