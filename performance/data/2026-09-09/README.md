# Paired Events measurements, 2026-09-09

The JSON files are original runner outputs, copied without editing. `counts`
means `[tests, assertions, failures, errors, skips]`; `exit: 124` marks a timeout.
Times are seconds. Child CPU is summed across child processes and may exceed wall
time. Cache fields record publication and selection, not merely test success.

| Files | Testmon revision | Source run |
| --- | --- | --- |
| `eb9-off-on.json`, `eb9-on-off.json` | `eb9db4989ef903642df4d05c4f4ffb0e6f0f15d4` | [34407485205](https://github.com/mikz/events-app/actions/runs/34407485205) |
| `6e-off-on.json`, `6e-on-off.json` | `6e1634d53b4bd238a8962cbd358f04e2a5cf8391` | [34406143545](https://github.com/mikz/events-app/actions/runs/34406143545) |
| `6e-240s-off-on.json`, `6e-240s-on-off.json` | `6e1634d53b4bd238a8962cbd358f04e2a5cf8391` | [34403127861](https://github.com/mikz/events-app/actions/runs/34403127861) |

Consumer source fixture: `mikz/events-app` at
`eea6ea43c53f134d9ce40fbbf4470995a9bbee55`. Benchmark-only branch
`codex/testmon-native-benchmark` changed the gem pin and added the runner/workflow.
The `eb9` run used benchmark branch head `23d0ac6`; the earlier `6e` run used
`1fc5c676`. Ruby 4.0.6, Rails 8.1.3.1, Minitest 6.0.6; Ubuntu hosted runners;
seed 3675; two workers; `bin/rails test:all --seed 3675`.

Both `eb9` pairs are complete. The `6e` on-first job timed out before a baseline
and must not enter a ratio. Workflow failure also includes the historical 30%
performance assertion, which is distinct from a test or publication failure.
Both first children in the earlier `240s` files timed out; neither order provides
a complete comparison. That run predates the archived harness's 420-second cap
and 30% assertion (it used a 240-second child cap and 10% assertion).

The [archived Python runner](../../harness/events-paired.py) and
[workflow](../../harness/events-workflow.yml) preserve the exact 420-second full,
60-second warm, and 20-minute job bounds of these runs. The runner is intended
for the isolated Events checkout, not this gem repository. Its old 30% assertion
is part of the historical experiment, not the current acceptance policy.

To reproduce, create an isolated Events checkout at the fixture revision, pin
the specified Testmon commit, install the fixture's locked Ruby/Bun dependencies
and Playwright Chromium, then invoke the runner once per fresh checkout with
`off-on` or `on-off`. It deliberately refuses to reuse its output directory.
Retain the resulting database for the warm phase; do not delete an existing cache.

To recompute the combined `eb9` wall overhead from this directory:

```sh
python3 - <<'PY'
import json
from pathlib import Path
rows = [row for name in ('eb9-off-on.json', 'eb9-on-off.json')
        for row in json.loads(Path(name).read_text())]
totals = {mode: sum(row['wall_seconds'] for row in rows if row['mode'] == mode)
          for mode in ('off', 'on')}
print(f"{100 * (totals['on'] / totals['off'] - 1):.3f}%")
PY
```

## Small final-snapshot experiment

`synthetic-final-snapshot-baseline.json` and
`synthetic-final-snapshot-candidate.json` are original deterministic harness
summaries from sequential runs `20260909T212658-c30cba` and
`20260909T212716-b85e94`. Baseline: `d97ec34`; candidate: `7355354` (later integrated
as `eb9db49`). Both use Ruby 4.0.6 on arm64 macOS, seed 417, 24 tests, 121 sources,
160 iterations, and 113 shared configuration files. They preserve individual
timings and cold/warm/mutation cache oracles.

Median enabled wall time fell from 1.140283 to 1.051615 seconds, about 7.8%.
This is a brief synthetic comparison, not a representative Rails overhead result
or an alternating-revision experiment. See the
[harness profile caveat](../../../benchmark/deterministic.md#optional-shared-configuration-profile)
before comparing it to the default workload.
