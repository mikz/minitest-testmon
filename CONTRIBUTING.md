# Contributing

Use Ruby 4.0.6 and install dependencies:

```sh
bin/setup
```

Run the default unit and style checks:

```sh
bundle exec rake
```

The full black-box suite requires PostgreSQL:

```sh
bundle exec rake test:acceptance
```

Keep changes focused, add regression coverage, and do not weaken fail-open
selection or fail-closed publication behavior.
