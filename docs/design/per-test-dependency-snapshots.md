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

The parent records execution intent before tests start. Selected tests receive
retry flags before any execution. Passing tests can clear their flags only when
complete dependency evidence has been accepted in a checkpoint.

At result boundaries, Testmon checkpoints after 25 pending passing tests or five
seconds since the previous checkpoint. After the first batch, it also waits at
least 19 times the previous checkpoint's elapsed cost, capped at 30 seconds.
This amortizes checkpoint work toward a 5% share while bounding the delay before
the next result boundary can save progress. It is a scheduling budget, not a
guarantee of total instrumentation overhead. Normal completion always flushes
the remainder without waiting for the interval.
Each checkpoint validates the original source, inventory, and configuration
snapshot before and after building dependency snapshots. The SQLite transaction
replaces accepted snapshots, clears their retry flags, advances the current
revision, and records the accepted IDs together. The run's starting revision
remains unchanged in its receipt and worker identities.

Claims are processed incrementally without closing active observers. Providers
with a finalization hook retain final-only publication because their evidence
cannot be certified while they are still observing.

Source drift stops further learning for the run. Pending results are discarded;
earlier checkpoints remain. The next run still compares their fingerprints
against current inputs. Test failures do not discard unrelated passing
checkpoints. Skipped, unfinished, and unverified tests retain retry state.
Duplicate or contradictory outcomes revoke the implicated checkpoint and force
a retry.

Run completion and cache progress are separate. A failed or abandoned run can
have accepted checkpoints without certifying a successful suite. Receipt schema
3 includes `checkpoints.count`, `checkpoints.accepted_ids`, and
`checkpoints.stop_reason`. SQLite schema 8 adds checkpoint receipt metadata;
versions 6 and 7 migrate transactionally without deleting cached snapshots.
Version 6 inputs conservatively migrate as suite inputs because they lack scope.

## Parallelism

Serial execution has one active coverage boundary. Rails process workers each
record observations and exact executed IDs to a run-scoped spool. Each completed
test also seals an atomic, synced completion frame before its result reaches the
parent. The parent checks the frame identity, outcome, and worker sequence before
including it in a checkpoint. Workers do not open SQLite.

A missing or incomplete frame cannot become a checkpoint. After parent death,
only committed SQLite checkpoints are reused; uncommitted frames are not
salvaged. Final spool validation still determines whether the run completed. An explicit
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
6. Failures and interruptions preserve accepted checkpoints; contradictory evidence
   for an accepted test revokes its checkpoint and forces a retry.
