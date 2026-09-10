# September 2026 Testmon optimization investigation

Recorded 2026-09-10. This consolidates the experiments behind
[PR #15](https://github.com/mikz/minitest-testmon/pull/15) and the cache corrections
in [PR #16](https://github.com/mikz/minitest-testmon/pull/16).

## Outcome and scope

PR #15 merged as `d44d61fe84caf11f83292ee39cc400e81252fdb0`; its tested branch
head was `36275e0d62a5f015bee163a81d958a08a7870f15`. The full paired benchmark used
`eb9db4989ef903642df4d05c4f4ffb0e6f0f15d4`, before the final test-name-only rename.
PR #16's code head `43719f89437e2187305517915d1449726c67e064` adds three correctness
fixes. It has no representative paired performance result yet.

The original 10% target, then 30%, was not reached. The user subsequently accepted
roughly 51% if profiling revealed no major avoidable hotspot. The measured
combined result is 52.4%, with substantial variation. Acceptance does not turn
that observation into a ceiling or prove that further savings are impossible.

## Representative measurements

The fixed Events application revision was
`eea6ea43c53f134d9ce40fbbf4470995a9bbee55`, with Ruby 4.0.6, Rails 8.1.3.1,
Minitest 6.0.6, seed 3675, two workers, and 872 tests / 9,944 assertions.
Two isolated Ubuntu jobs ran opposite orders. Enabled cold runs used a new
database; warm runs reused it. These were ordinary cold runs, not `--full`
generic File/IO auditing. Every valid full run passed all 872 tests.

| Revision / order | Off wall seconds | On wall seconds | Added wall time | Warm seconds |
| --- | ---: | ---: | ---: | ---: |
| `eb9db49`, off-on | 277.157291 | 399.158738 | 44.0% | 23.976982 |
| `eb9db49`, on-off | 252.947719 | 408.591015 | 61.5% | 23.866908 |
| `6e1634d`, off-on | 264.403523 | 399.291473 | 51.0% | 24.268199 |
| `6e1634d`, on-first | No completed pair | Exceeded 420-second cap | Invalid | Not reached |

For `eb9db49`, `(sum(on) / sum(off) - 1) * 100` is 52.375%, reported as 52.4%.
This is a ratio of totals, not an average of the two percentages. Both enabled
runs published 872 snapshots, with no diagnostics or retries. Both warm runs
selected zero tests and published successfully.

Raw results and provenance are in [data/2026-09-09](data/2026-09-09/README.md).
The workflow failed its historical 30% assertion; tests and publication passed.
An earlier run capped both off and on at 240 seconds and provides no ratio.
Local adjacent runs, runs under competing CPU load, interrupted runs, and runs
with different source trees were exploratory only. They are not acceptance data.
Worktree isolation prevents source interference, not shared-host CPU contention.

## Work that shipped in PR #15

Individual gains below must not be added together. Most changes were evaluated
as a combined revision; a correctness pass alone is not evidence of a speedup.

| Change | Work eliminated or corrected | Evidence and limits |
| --- | --- | --- |
| Native event/method filtering and shared observer router | Reject irrelevant TracePoint events before calling Ruby | Native lifecycle, exceptions, aliases, GC, threads, forks, and package-loading gates passed. Public MRI APIs with Ruby fallback; no Rust/Magnus extension was needed. |
| Shared native-accessor source census | Promote known accessor source files to shared dependencies and remove an extra global `c_call` hook | The first prototype added repeated database rows and did not help. Adopted with normalized storage and the whole-file identity correction below. Whole-file invalidation trades some selectivity for less observation. |
| Immutable shared input sets, SQLite schema 9 | Store one shared set instead of repeating it for every test | 872 tests × 113 inputs changed from 98,536 member rows to 113 members and one set. Expanded relationships, migration from schemas 6–8, historical snapshots, leases, and selection remained covered. |
| Incremental checkpoint state and indexes | Avoid repeated claim scans and reconstruction of unchanged provider state | Combined cold publication and warm zero-selection passed. |
| Adaptive checkpoints | Avoid repeatedly paying expensive checkpoint work | First checkpoint remains prompt: 25 tests / 5 seconds; later intervals use measured cost, a 5% budget, and a 30-second cap. This does not extend CI deadlines. |
| Coverage delta-first resolution | Resolve paths only after finding executed coverage deltas | A worker profile had about 13.65 seconds of `File.realpath` under Coverage snapshots. External Coverage and independent snapshots remain supported. |
| Inventory pruning and pass-local path reuse | Avoid globbing excluded subtrees and repeating file classification within a pass | Hidden files, ordering, symlinks, and fresh later validation retain parity tests. Isolated inventory timing gains were small and noisy. |
| Constant parse plans | Parse source/line reference syntax once | Live constant resolution still happens on each event, including removal, redefinition, and alias changes. Small same-profile comparisons improved about 6–13%; not full-suite attribution. |
| Validate final accepted evidence without rebuilding every Snapshot | Remove redundant construction while retaining validation | Shared-profile median wall time changed from 1.140283 to 1.051615 seconds in a brief sequential comparison. All cache oracles passed. Initial unsafe shortcut was rejected; see below. |
| Atomic worker spool records and completion drains | Prevent concurrent worker writes from corrupting evidence | Malformed streams remain rejected; complete evidence is required before publication. This is also a reliability fix. |
| Atomic cache initialization and bounded SQLite busy handling | Avoid partially visible schemas and transient physical-lock failures | Transactional initialization and a 250 ms physical-lock timeout fixed deterministic reproductions. Logical lease refusal remains immediate; the existing 40-second interruption test was unchanged. |

Additional correctness fixes included failed targeted-TracePoint enable cleanup
(fingerprint algorithm 5), canonical fixture roots/order/default identity, and
the normal-mode generic File audit gate. Native event filtering must honor
`observe_files: false`; otherwise ordinary application IO becomes unexpected
audit evidence. Do not hide these failures by muting diagnostics.

## Rejected and deferred experiments

| Approach | Result / reason | Requirement before revisiting |
| --- | --- | --- |
| Drop Coverage snapshots, including freshly owned Coverage | **Rejected: missing evidence.** Uppercase constant resolution triggered autoload inside a TracePoint callback, suppressing `script_compiled`. A later method's source was observed only through `coverage_delta`, with no diagnostic warning. | Preserve this autoload/reentrant-callback case, retained methods, and custom coverage claims through an independent complete observer. The initial CamelCase probe was invalid for the uppercase constant scanner; use the corrected case. |
| Thread-owner filtering in the native callback | **Removed: no measured gain.** Full enabled run took 154.953 seconds versus 151.865 in the adjacent normalized candidate. | Show that the change removes meaningful VM work. Filtering callbacks does not remove global event dispatch. |
| Targeted return-only worker boundaries | **Reverted.** Local checks passed but hosted Linux reported late completion; no measured full-suite improvement justified the complexity. | Reproduce nested dispatch, callback event replay, and hosted completion ordering before timing. |
| Explicit Rails Worker adapter with lifetime per-thread traces | **Deferred.** Redesigned version passed bounded correctness cases, but the full timing run was interrupted/contaminated. MRI scans the Ractor hook list before thread filtering. | Demonstrate savings in a controlled pair and preserve constructor/nested-thread boundaries. No speedup established. |
| Attach the run hook on entry, depth guesses, or narrow startup class census | **Rejected: boundary gaps.** A constructor can define singleton `run` from a precompiled block; dynamic definitions and direct nested runs also matter. | Prove observation starts before execution for these cases. |
| Narrow accessor declaration facets | **Design only.** Literal Prism-parsed declarations may permit finer invalidation; dynamic generators, facet removal, and empty/fallback census transitions complicate it. | Complete stable census and conservative whole-file fallback. No implementation or measured gain. |
| Naive late script/native-source promotion | **Insufficient.** Suite observations without a test can be ignored, early checkpoints need final reconciliation, and precompiled generators need not emit a compilation event. | Cover each route separately. PR #16 reconciles final known suite inputs; it does not prove complete late-accessor discovery. |
| Reuse accepted snapshots without validating final evidence | **Initial version rejected.** Malformed late providers could supply nil fingerprints or missing claims. | Keep duplicate-ID, claim, knownness, and test-definition precedence validation. The corrected version shipped. |
| Deep sealing/copying report evidence | **Deferred, unmeasured.** Adds an initial traversal; focused correctness passed. | Measure net saved allocations and time rather than assuming reuse wins. |
| Capture initial validation fingerprints during artifact construction | **Deferred after prototype.** Removed redundant initial reads in the configured provider; focused mutation/compiler checks passed. Full profiling put source validation around 2.3 coordinator CPU seconds, too small to justify broader rollout scope then. | Capture the bytes actually used for artifacts; a later independent read creates an artifact-A/baseline-B race. Retain both stability guards and custom-provider fallback. |
| Suppress observation of validation File calls | **Not implemented.** User/custom digest code may run inside validation. | Define a safe internal-only boundary and measure it before suppressing events. |
| Rust extension via Magnus | **Considered, not implemented or benchmarked.** Existing C filtering addressed the native boundary; remaining work required attribution and storage changes. | Identify a measured Ruby hotspot worth the packaging and maintenance cost. |

## Profiling findings and traps

Vernier 1.11 helped identify startup callbacks, repeated validation, claim scans,
and worker waits. An allocation-enabled full profile stalled in a fiber-event /
allocation-hook mutex path. It was stopped; that duration is not a benchmark.
Later diagnostic runs disabled allocation sampling.

StackProf 0.2.28 CPU sampling at 1,000 microseconds captured the coordinator and
both workers separately on `eb9db49`. The coordinator had 7,792 samples; source
stability accounted for 2,344 inclusive samples (about 2.3 sampled CPU seconds).
Workers had about 65,000 samples each. `Process.clock_gettime` accounted for
18.7% / 20.2% self samples, almost entirely Rails Notifications `Event#now_cpu`.
The matching Testmon-off profile also spent about 21.8% there. This was not
established as a Testmon-specific hotspot.

Do not sum inclusive parent and child frames: `Store.publish` includes report
rendering, and attribution wrappers include application work. Sample percentages
from separate runs cannot be subtracted to derive exact overhead. Wall profiles
include idle and blocked time; GVL-running categories are not CPU samples.
Process signal delivery can bias CPU sample attribution. These profiles did not
cover every startup phase, so absence of a hotspot is not proof of zero cost.

## Cache correctness discovered during rollout

These PR #16 fixes are prerequisites for a useful experience even when timing
is acceptable. Passing application assertions alone does not prove a usable cache.

| Reproduction | Fix and regression evidence |
| --- | --- |
| CorrSen generated mailer test names contain another `#`; five passing tests could not publish their definitions | Split the ID at its first separator (`partition`), since Ruby class names cannot contain `#`. Regression covers cold publication and zero warm selection. Three genuinely skipped tests are separate from this defect. |
| Events learned a shared source after early checkpoints; first warm run reran 144 tests, second ran zero | Final publication unions validated shared inputs into this run's accepted passing checkpoints using immutable sets. Historical retained rows stay unchanged; conflicts roll back. The preserved old set had 213 members versus 214 final members; the original per-test mapping had already been overwritten, limiting retrospective proof. Focused regressions cover the early/late case directly. |
| Community futures and Action Cable callbacks ran on prewarmed threads without the registering test's context | Capture explicit revocable tokens at task/callback registration; borrow only for invocation and restore executor state. The real RequestHandle test published with no diagnostics, then selected zero on repeat. |

Capturing only at executor `post` is insufficient: test A can register a
continuation that test B later resolves. Guessing the sole active test is also
unsafe. Action Cable uses subscribe-only callable wrappers with equality that
preserves original-callback unsubscribe and duplicates. A stateful wrapper map
was discarded to avoid changing adapter locking and ordering. Unsupported async
APIs remain conservative. Adapter tests run Rails in a subprocess to avoid
changing unrelated fixture tests through global loading.

PR #16 code validation: 306 tests / 1,619 assertions passed, followed by an added
final-payload assertion verified in a 5-test / 36-assertion focused run. Hosted
unit/native and acceptance checks passed in about 1m39s and 8m27s, respectively.
This is correctness evidence, not a final PR #16 overhead measurement.

## Next optimization protocol

1. Use a dedicated checkout and the [deterministic harness](../benchmark/deterministic.md).
   Keep the same workload across revisions. Its default seed is 417; it uses real
   JSON, strings, hashes, Ruby calls, and native accessors without sleeps or padding.
2. Require cold publication, warm zero-selection, precise ordinary-source
   invalidation, and shared-source invalidation before considering a speedup.
3. Compare like profiles. `DETERMINISTIC_SHARED_INPUTS=113` adds real config work
   **and suppresses the default generic File provider**, so comparing it against
   the default does not isolate storage cost. Phase timings can overlap.
4. Profile a bounded candidate and matching baseline. Prefer eliminating work;
   do not replace a correctness guard with an optimistic assumption.
5. For representative acceptance, freeze the consumer and Testmon commits, run
   both orders with identical counts, and preserve raw results. Testmon-off is
   authorized only for isolated benchmark controls. Correctness tests keep it on.
6. Keep deadlines bounded: the archived full harness caps each full child at
   420 seconds, warm at 60 seconds, and jobs at 20 minutes. A timeout is an invalid
   comparison, not permission to extend CI to 75 minutes.
7. Record final-version results before claiming final overhead or asking consumers
   to re-enable. Next priorities are PR #16 paired measurement and full consumer
   publication/warm checks. Revisit deferred work only with a measured benefit.
