# frozen_string_literal: true

require "fileutils"
require_relative "support/testmon_plugin_state"

load_order = ENV.fetch("REPORTER_LOAD_ORDER")

case load_order
when "clean"
  require_relative "support/reporter_compat"
  ReporterCompat.configure!
when "testmon_then_reporters_then_rails"
  raise "testmon plugin was not preloaded" unless ReporterTestmonPluginState.active?
  require_relative "support/reporter_compat"
  ReporterCompat.record_boot("testmon_before_reporters", ReporterTestmonPluginState.snapshot)
  ReporterCompat.configure!
when "reporters_before_testmon"
  raise "reporters-first preload did not run" unless defined?(ReporterCompat) && ReporterCompat.configured?
  raise "testmon plugin was not loaded after reporters" unless ReporterTestmonPluginState.active?
  ReporterCompat.record_boot("testmon_after_reporters", ReporterTestmonPluginState.snapshot)
when "duplicate_plugin_require"
  raise "testmon plugin was not preloaded" unless ReporterTestmonPluginState.active?
  require_relative "support/reporter_compat"
  first = require "minitest/testmon_plugin"
  second = require "minitest/testmon_plugin"
  ReporterCompat.record_boot(
    "duplicate_plugin_require",
    "first_require" => first,
    "second_require" => second
  )
  ReporterCompat.configure!
when "custom_delegate_reporter"
  raise "testmon plugin was not preloaded" unless ReporterTestmonPluginState.active?
  require_relative "support/reporter_compat"
  ReporterCompat.record_boot("custom_delegate_reporter", ReporterTestmonPluginState.snapshot)
  ReporterCompat.configure!(custom_delegate_target: true)
else
  raise "unknown REPORTER_LOAD_ORDER: #{load_order.inspect}"
end

ReporterCompat.assert_supported_version!

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "../lib/rails_policy_loader"

parallel_workers = Integer(ENV.fetch("PARALLEL_WORKERS", "2"))
parallel_mode = ENV.fetch("PARALLEL_MODE", "processes").to_sym
raise "reporter compatibility requires Rails process parallelization" unless parallel_mode == :processes

ActiveSupport::TestCase.parallelize workers: parallel_workers, with: :processes, threshold: 0

if (snapshot_path = ENV["REPORTER_API_SNAPSHOT_PATH"])
  ReporterCompat::PublicApiSnapshot.write(snapshot_path)
end
