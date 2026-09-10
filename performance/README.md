# Performance records

Keep measurements, experiment decisions, and reproduction instructions here.
Start with the [September 2026 investigation](2026-09-investigation.md) before
repeating an optimization. The fast local harness lives in
[benchmark/deterministic.md](../benchmark/deterministic.md).

## Latest recorded result

On the fixed Events fixture, Testmon `eb9db4989ef903642df4d05c4f4ffb0e6f0f15d4`
added **52.4% wall time across two opposite-order pairs**. Individual pairs added
44.0% and 61.5%. Both warm runs selected zero tests and took about 24 seconds.
This is evidence for the PR #15 candidate, **not a measurement of PR #16**.
The range is not a guaranteed upper bound.

## Folder conventions

- `data/`: small, original measurement files and explicit provenance. Preserve
  unsuccessful runs and label them; never silently remove an inconvenient result.
- `harness/`: archived consumer benchmark runners and their workflow settings.
  These are reproduction references, not workflows enabled in this repository.
- Dated investigation records: what changed, what passed, what failed, and what
  evidence would justify revisiting a rejected or deferred approach.

For each new experiment record the Testmon and consumer commits, Ruby and gem
versions, workload, seed, worker count, execution order, deadlines, profiler
settings, test counts, cache publication, retries, and warm selection. Keep
profiled timings separate from unprofiled comparisons. Attach durable links or
small exported summaries for large profiles; temporary filesystem paths alone
are not a record. Do not commit caches, installed dependencies, secrets, or large
generated profiler dumps.
