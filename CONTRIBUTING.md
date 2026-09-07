# Contributing

Use Ruby 4.0.6. Install the locked Ruby, BundleBun, and Playwright
dependencies, including Chromium:

```sh
bin/setup
```

Run the default unit and style checks:

```sh
bundle exec rake
```

The full black-box suite also requires PostgreSQL. Run all checks, including
the real-browser Rails suite:

```sh
bundle exec rake ci
```

Keep changes focused, add regression coverage, and do not weaken fail-open
selection or fail-closed publication behavior.
