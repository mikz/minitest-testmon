# Direct file reads and cache publication

Issue #17: native TracePoint cannot expose a `File.read(path)` argument. Community
kept 20 opaque observations and could not publish its Rails run. Replacing that
unknown path with a guessed literal would not establish a dependency.

## What worked

A narrow prepend on IO's singleton `read`, `binread`, `readlines`, and `foreach`
methods captures the real path before native dispatch. File inherits those
methods. The wrapper converts a path once, preserves lazy enumeration, and
records nested reads made during user path conversion. Existing Ruby source
facets hash the complete file bytes, so direct Ruby reads use those facets.
No new fingerprint format or second content inventory was needed.

Logical callsite paths also needed normalization before applying the existing
project/exclusion policy. Otherwise the core provider could mistake a project
read for an external call and ignore its evidence. Unclaimed direct reads now
block publication with `uncovered_file`.

Community exposed two more input categories once paths were visible: Markdown
mail bodies and temporary files produced by its own tests. Its consumer update
declares the Markdown bytes and narrowly ignores generated temporary paths only
for their owning test classes. Repository Ruby inputs remain tracked.

Community validation on `cee1a77`: full local CI passed in 2m30s; all 865 Rails
tests and 80 system tests published with no diagnostics. Both unchanged warm
runs selected zero tests. A comment-only change to `Archspec.rb` selected exactly
nine query-ownership tests. A newline change to the password-reset Markdown
selected its dependent tests (13 total, including the nine tests whose restored
Archspec bytes changed back). Both mutation runs passed and published. Probe
edits were restored, and caches were preserved.

Events validation on `611bc11`: full local CI passed 1,250 tests with 12,994
assertions in 6m20s, published all checkpoints, and warm reuse selected zero.
These are candidate results; final rollout evidence belongs in the consumer PRs.

## Experiments and rejected approaches

- Guarding path conversion suppressed real reads inside `to_path`. The guard
  now surrounds observer dispatch only; a regression test checks both reads.
- Enabling global native file auditing merely because the Ruby provider claims
  `file_read` would undo the performance work. The activation predicate excludes
  this built-in claim; a regression test holds that boundary.
- Resolving a path without requiring a provider claim could publish incomplete
  evidence. An explicit regression requires an unclaimed read to remain incomplete.
- Old API snapshots forbade all prepends. They now permit precisely the four
  direct-read entry points while checking the remaining public APIs unchanged.
- Forcing `MINITEST_TESTMON=1` onto the whole acceptance runner contaminated its
  intentionally plain subprocess probes. The standard CI entry point lets each
  scenario choose activation; Testmon correctness scenarios enable it explicitly.
- No native extension changes were needed for path capture. Saved native methods
  and aliases that bypass the prepend remain outside this wrapper's coverage;
  native audit mode rejects opaque calls. Non-main Ractor attribution remains
  unsupported. Do not claim this patch establishes universal IO tracking.

## Bounded performance check

The [raw data](data/2026-09-10-direct-reads/) preserves all three off/on pairs,
phase measurements, and warm/mutation oracles for each profile. Baseline is
`b748cf6`, candidate is `cee1a77`, Ruby 4.0.6 on macOS arm64. Both use the existing
24-test, 121-source, seed-417 harness without workload changes.

| Profile | Baseline mean cold | Candidate mean cold | Baseline warm | Candidate warm |
| --- | ---: | ---: | ---: | ---: |
| Generic native file audit | 1.0102 s | 0.9324 s | 0.3371 s | 0.3660 s |
| 113 shared inputs, native file audit off | 0.5000 s | 0.4935 s | 0.3596 s | 0.3493 s |

All cache oracles passed with zero retries. These short runs show no material
cold-run regression; their timing spread does not establish an improvement.
The generic profile's overhead is several times its tiny native control. These
synthetic ratios are not Rails suite overhead and do not replace the historical
52.4% Events measurement. No final full-suite paired overhead claim is made here.
