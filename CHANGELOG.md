# Changelog

## Unreleased

- Hash complete observation identities with a binary-safe canonical encoding,
  including Unicode test names and source paths.
- Let real Capybara/Puma and Playwright system suites publish: only threads
  defined in the sealed Ruby inventory inherit test-lifetime attribution.
  Application thread leaks and unfinished Rack requests still block publication.
- Classify unattributed input through provider claims instead of reporting a
  false late observer activation for ignored external framework loads.
- Verify real-browser `test:all` cold publication, warm selection, and view edits.
- Attribute synchronous Puma configuration loading and mode hooks during
  Capybara startup without attaching the persistent server thread to a test.
- Preserve suite-scoped evidence for shared server configuration and its
  children. Reject test-only startup dependencies instead of under-selecting
  later system tests.

- Exclude repository-local dependency Ruby under paths such as `vendor/bundle`
  from both inventory and runtime evidence, including opaque file reads, so
  serial and process-parallel Rails runs can publish complete evidence.
- Prevent Testmon problems from failing an otherwise successful test run. Tests
  still run once; Testmon warns and keeps the last known-good cache.
- Select from literal per-test dependency snapshots: every test stores the
  exact checksum of each learned input, so an accepted run never refreshes a
  test it did not execute. `bin/rails test` and `bin/rails test:all` can share
  one database safely.
- Persist Ruby inputs as SHA-256 of exact source bytes. MRI instruction
  sequences are used only to probe targeted TracePoint capability.
- Give every inventory exactly one suite-scoped path-membership input and copy
  current suite inputs into every passing test snapshot. Additions, deletions,
  and renames therefore select every discovered test conservatively.
- Use one ordered selected-test list with reasons. There are no `all`, `subset`,
  or `none` modes; `run --full` simply selects every runnable with reason
  `forced`.
- Reject publication atomically when any selected test fails, preserving every
  previously accepted snapshot.
- Collapse the old `discover` command into `run`; use `run --full` for provider
  validation.
- Support `bin/rails test:all`: system tests run as ordinary tests, the
  accepted complete-suite file globs are configurable
  (`complete_suite_globs`, with the Rails profile default), and the wrapper
  accepts `run -- bin/rails test:all`.
- Attribute Capybara/Puma request threads to the sole active system test through
  request-scoped middleware; reject other unattributed background execution.
- Add the `rails.assets@1` provider: Propshaft asset resolutions claim asset
  content per test; importmap/package manifests, lockfiles, and
  `app/javascript` are claimed by every asset-resolving test.
- Store current per-test snapshots and retained run receipts in SQLite.
- Rebuild schema-v6 state on first use. An incompatible older database is
  preserved as `.minitest-testmon.sqlite3.incompatible-<timestamp>-<pid>` and
  the first run starts with a cold cache.
- Keep the latest 10 run reports by default, with a configurable retention limit.
- Replace the persistent JSON report with `minitest-testmon report`.
- Remove report-path configuration, environment variables, and CLI flags.
- Accept `1`, `true`, `yes`, and `on` in `MINITEST_TESTMON` as an alternative
  to `--testmon`.

## 0.1.0

- Initial public release.
- Conservative Minitest selection for MRI Ruby 4.
- Rails 8.1 providers and native process-parallel test support.
- Custom provider and discovery APIs for non-Ruby inputs.
