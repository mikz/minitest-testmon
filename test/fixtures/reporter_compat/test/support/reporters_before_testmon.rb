# frozen_string_literal: true

require_relative "testmon_plugin_state"

if ReporterTestmonPluginState.feature_loaded? || ReporterTestmonPluginState.extension_registered?
  raise "testmon plugin loaded before the reporters-first preload"
end

require_relative "reporter_compat"

ReporterCompat.configure!
ReporterCompat.record_boot(
  "reporters_before_testmon",
  ReporterTestmonPluginState.snapshot
)
