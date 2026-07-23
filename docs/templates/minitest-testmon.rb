# frozen_string_literal: true

# Copy this file to .minitest-testmon.rb.
Minitest::Testmon.configure do |config|
  config.version 1

  # :project defaults to Dir.pwd. Use __dir__ when commands may start elsewhere.
  config.root :project, __dir__

  config.database ".minitest-testmon.sqlite3"
  config.report "tmp/minitest-testmon/discovery.json"

  # lib/**/*.rb and test/**/*.rb are included by default.
  # Rails 8.1 automatically adds app/**/*.rb.
  # config.ruby_files "components/**/*.rb"

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
