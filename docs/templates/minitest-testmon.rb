# frozen_string_literal: true

# No configuration file is required for the defaults. Copy this file to
# .minitest-testmon.rb only to override a default or add custom inputs.
Minitest::Testmon.configure do |config|
  # lib/**/*.rb and test/**/*.rb are included by default.
  # Rails 8.1 automatically adds app/**/*.rb.
  # config.ruby_files "components/**/*.rb"

  # The SQLite state path is relative to :project.
  # config.database "tmp/minitest-testmon/state.sqlite3"

  # Testmon retains the latest 10 run reports by default.
  # config.retained_reports 25

  # Add another stable logical root when inputs live outside the project root.
  # config.root :shared, File.expand_path("../shared", __dir__)
  # config.ruby_files "lib/**/*.rb", root: :shared

  # A coarse built-in fileset is useful when runtime attribution is impossible.
  # Prefer a provider when the input can be assigned to individual tests.
  # config.fileset :generated_contracts,
  #   root: :project,
  #   include: ["config/contracts/**/*.json"],
  #   exclude: ["config/contracts/generated/**/*"],
  #   mode: :contents,
  #   scope: :suite

  # Custom providers are versioned configuration. See docs/providers.md.
  # config.provider :application_settings, version: 1 do
  # end

  # Rails 8.1 providers are automatic. Uncomment to disable all five.
  # config.disable_bundle :rails_8_1
end
