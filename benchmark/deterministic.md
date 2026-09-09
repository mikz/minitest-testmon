# Deterministic local performance iteration

Run from this worktree:

```sh
bundle exec rake compile
bundle exec ruby benchmark/deterministic.rb
```

The native extension is required for enabled measurements. No profiler gems are
installed. Every invocation preserves a unique directory under
`benchmark/deterministic-results/`, containing generated sources, child logs,
phase metrics, SQLite caches and `summary.json`. Do not commit generated results.

Defaults: 24 tests, 121 Ruby source files, seed 417, three alternating off/on
pairs. Each test builds and parses JSON records using project method calls,
native accessors, strings and hashes. The work performs checked calculations;
there are no sleeps or workload padding. Each child has a 30-second process-group
timeout. Default completion should take well below 60 seconds.

The off runs are isolated benchmark controls, explicitly authorized for this
harness. Every correctness check enables Testmon and requires publication with
zero retries. Cold measurements use separate fresh caches. The first cold cache
then proves unchanged warm retention, precise ordinary-source selection and
shared accessor-source invalidation. All caches are preserved.

`DETERMINISTIC_REPEATS`, `DETERMINISTIC_TESTS` and `DETERMINISTIC_ITERATIONS`
override the defaults. Keep tests at most 120, since there are 120 worker source
modules. Use identical settings across compared revisions. More CPU iterations
change the workload balance; they must not be used to manufacture a target ratio.

Metrics distinguish wall time, process CPU, summed test `run` time, Runtime
installation, checkpoint flushing, and final reporter time. Checkpoint flushing
can occur inside final reporting: these columns overlap and must not be summed.
Installation excludes Ruby/gem loading before Runtime starts. Instrumentation is
identical between paired workloads where the corresponding phase exists.

This is a small synthetic regression workload, not representative Rails
performance or proof of a full-suite 10% overhead target. Default generic file
auditing remains enabled; Rails process workers and browser work are absent.
