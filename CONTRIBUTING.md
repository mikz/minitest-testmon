# Contributing

Use Ruby 4.0.6 and install dependencies:

```sh
bin/setup
```

Run the default unit and style checks:

```sh
bundle exec rake
```

The full black-box suite requires PostgreSQL, Node.js, and Chromium matching
the Playwright client. Install the browser once:

```sh
playwright_version="$(bundle exec ruby -rplaywright -e 'print Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')"
npx --yes "playwright@$playwright_version" install chromium
```

Run all checks, including the real-browser Rails suite:

```sh
bundle exec rake ci
```

Keep changes focused, add regression coverage, and do not weaken fail-open
selection or fail-closed publication behavior.
