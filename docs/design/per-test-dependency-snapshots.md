# Per-test dependency snapshots

Status: **implemented**. This note describes the persisted model and the safety
rules used by the current runtime.

## Model

Minitest loads the tests and exposes runnable methods. Testmon then produces one
ordered list of test IDs to execute. A test is included when it has no snapshot,
has retry state, was explicitly forced, or one of the inputs in its own snapshot
no longer has the same fingerprint. An unchanged test is omitted.

Each successful test owns a literal snapshot of the inputs observed for that
test and the fingerprint of each input at that run. There is no mutable global
artifact fingerprint. Publishing one test therefore cannot make an omitted
test look current: the omitted test keeps its previous input fingerprints.

There are no `all`, `subset`, or `none` selection modes. `run --full` simply
adds every discovered test to the list with reason `forced`.

## Why this shape

[Ekstazi](https://users.ece.utexas.edu/~gligoric/papers/Gligoric15PhD.pdf)
records the files and checksums used by each test entity. The important property
is the ownership boundary: a test is judged against evidence from that test's
own last accepted execution. Testmon uses the same conservative shape while
extending an input beyond Ruby source to templates, configuration, schema, and
inventory membership.

The runtime is intentionally built on the host test stack:

- [Minitest 6](https://github.com/minitest/minitest/blob/v6.0.6/lib/minitest.rb)
  supplies discovery and filtering through `filter_runnable_methods`.
- [Ruby 4 Coverage](https://docs.ruby-lang.org/en/4.0/Coverage.html) supplies
  cumulative line counters. Serial tests use `Coverage.peek_result` deltas.
- [Ruby `Data`](https://docs.ruby-lang.org/en/4.0/Data.html) represents immutable
  input IDs, inputs, selections, and snapshots.
- [`RubyVM::InstructionSequence`](https://docs.ruby-lang.org/en/4.0/RubyVM/InstructionSequence.html)
  is MRI-specific and its format is not stable. Testmon uses it only to probe
  targeted TracePoint capability; it is not the persisted checksum format.
- Rails process workers execute test bodies in children and return results to a
  parent reporter. Testmon therefore records boundaries inside each worker and
  merges worker spools in the parent. See the Rails 8.1
  [worker](https://github.com/rails/rails/blob/v8.1.3/activesupport/lib/active_support/testing/parallelization/worker.rb),
  [server](https://github.com/rails/rails/blob/v8.1.3/activesupport/lib/active_support/testing/parallelization/server.rb),
  and [executor](https://github.com/rails/rails/blob/v8.1.3/activesupport/lib/active_support/testing/parallelize_executor.rb).
- SQLite remains single-writer. The parent enables
  [foreign keys](https://www.sqlite.org/foreignkeys.html) on every connection and
  publishes under
  [`BEGIN IMMEDIATE`](https://www.sqlite.org/lang_transaction.html).

## Inputs and fingerprints

An input identity is `(provider, key)`. A stored test input also records its
facet, logical root/path, state, and digest. Existing files use SHA-256 of the
exact bytes. This deliberately treats comments, whitespace, encoding bytes, and
line-ending changes as changes. It may run an extra test, but it cannot hide a
source edit behind an MRI- or compiler-dependent normalization.

Every inventory has exactly one path-membership input. Membership is always
suite-scoped because an ordinary successful lookup does not prove that the same
observer sees failed lookups or future shadowing files. The conservative KISS
rule is to copy every current suite-scoped input into every passing test's
snapshot. Consequently, adding, deleting, or renaming a member selects every
discovered test whose snapshot contains that membership checksum. There is no
persisted `*` pseudo-test.

The provider context signature is also represented as a suite-scoped input.
Provider/configuration, Ruby, gem, and algorithm changes therefore invalidate
ordinary per-test snapshots through the same comparison path.

## Durable schema

The selection tables are intentionally literal:

```sql
test_snapshots(
  test_id TEXT PRIMARY KEY,
  recorded_at TEXT NOT NULL,
  run_id TEXT NOT NULL
)

test_inputs(
  test_id TEXT NOT NULL REFERENCES test_snapshots(test_id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  input_key TEXT NOT NULL,
  facet TEXT NOT NULL,
  root TEXT,
  relative_path TEXT,
  digest TEXT,
  state TEXT NOT NULL CHECK (state IN ('known', 'missing')),
  PRIMARY KEY(test_id, provider, input_key)
)

retry_tests(
  test_id TEXT PRIMARY KEY,
  outcome TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
```

`metadata`, `leases`, and `run_receipts` hold the schema/revision, exclusive
writer lease, and retained reports. There is no separate fingerprints table,
artifact baseline, graph generation copy, command shape, TTL, or time-based
correctness rule. Snapshots for tests no longer presented by Minitest may remain
stored; they do not participate in selection.

## Selection

For each discovered test, selection applies these rules in order:

1. forced → run;
2. retry state from an interrupted, failed, or skipped execution → run;
3. no snapshot → run;
4. any learned input is absent, unknown, or has a different state/digest → run;
5. otherwise → omit.

A cold cache naturally selects every test by rule 3. A suite input or membership
change naturally selects every affected discovered test by rule 4. No separate
"full" branch is required for either case.

Minitest filtering happens twice for distinct purposes: first, after test loading,
`filter_runnable_methods` defines the discovered list; then Testmon replaces the
positive filter with the exact selected IDs. The publication ledger requires the
selected and executed lists to match exactly and rejects duplicate outcomes.

## Publication

The parent records execution intent before tests start. Publication is one
SQLite transaction and is accepted only when:

- the provider and worker evidence is complete;
- the source/inventory snapshot is unchanged from start to finish;
- selected tests executed exactly once and outcomes cover the exact ledger;
- every passing test has a complete snapshot containing only known inputs; and
- no selected test failed.

On acceptance, each passing test atomically replaces only its own snapshot and
input rows. Omitted tests are untouched. Skipped tests retain retry state and are
selected again. On any test failure, the entire run is rejected: no passing
snapshot from that run replaces durable dependency state. The failure is kept as
retry state and the last accepted revision remains authoritative.

This atomic-on-any-failure rule is stricter than per-test isolation requires,
but it is the public contract and keeps one simple definition of an accepted
run. Incomplete evidence, source drift, worker loss, a ledger mismatch, or lease
failure is rejected the same way.

## Parallelism

Serial execution has one active coverage boundary. Rails process workers each
record observations and exact executed IDs to a run-scoped spool; workers do not
open SQLite. The parent validates all spools and publishes once. An explicit
`parallelize_me!` uses that supported path when Rails process parallelization is
active. Thread-backed Minitest parallel tests and Rails thread workers are
rejected because Ruby Coverage and framework notifications are process-global
and overlapping test boundaries cannot be attributed safely.

## Core invariants

1. A test is selected from its own stored input checksums.
2. No snapshot or uncertain evidence can only cause more execution.
3. An accepted run writes only passing tests that actually executed.
4. An omitted test's snapshot is never refreshed by another test.
5. Membership and other suite inputs are explicit inputs copied into snapshots,
   not hidden global state.
6. Any failed or incomplete run preserves the previous accepted snapshots.
