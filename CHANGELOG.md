# Changelog

## Unreleased

- Store retained graph generations and discovery receipts in SQLite.
- Replace the persistent JSON report with `minitest-testmon report`.
- Remove report-path configuration, environment variables, and CLI flags.
- Accept `1`, `true`, `yes`, and `on` in `MINITEST_TESTMON` as an alternative
  to `--testmon`.

## 0.1.0

- Initial public release.
- Conservative Minitest selection for MRI Ruby 4.
- Rails 8.1 providers and native process-parallel test support.
- Custom provider and discovery APIs for non-Ruby inputs.
