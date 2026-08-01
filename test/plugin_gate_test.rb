# frozen_string_literal: true

require_relative "test_helper"
require "minitest/testmon_plugin"

class PluginGateTest < TestmonTestCase
  ALL_SUITE_GLOB = "test/**/*_test.rb"

  def test_rails_all_suite_requires_the_rails_test_command_context
    with_rails_command(nil) do
      refute Minitest.rails_all_suite_testmon?(testmon: true, test_files: [ALL_SUITE_GLOB])
    end
  end

  def test_rails_all_suite_accepts_exactly_the_configured_globs
    with_rails_command("test") do
      assert Minitest.rails_all_suite_testmon?(testmon: true, test_files: [ALL_SUITE_GLOB])

      refute Minitest.rails_all_suite_testmon?(testmon: true, test_files: ["test/models"])
      refute Minitest.rails_all_suite_testmon?(testmon: true, test_files: [ALL_SUITE_GLOB, "test/models"])
      refute Minitest.rails_all_suite_testmon?(testmon: true, test_files: [])
      refute Minitest.rails_all_suite_testmon?(testmon: true)
    end
  end

  def test_complete_suite_globs_are_configurable
    with_rails_command("test") do
      Minitest::Testmon.reset!
      Minitest::Testmon.configure do |config|
        config.complete_suite_globs "spec/**/*_test.rb", "test/**/*_test.rb"
      end

      assert Minitest.rails_all_suite_testmon?(
        testmon: true,
        test_files: ["test/**/*_test.rb", "spec/**/*_test.rb"]
      )
      refute Minitest.rails_all_suite_testmon?(testmon: true, test_files: [ALL_SUITE_GLOB])
    end
  ensure
    Minitest::Testmon.reset!
  end

  def test_profile_default_does_not_clobber_a_customized_configuration
    Minitest::Testmon.reset!
    configuration = Minitest::Testmon.configure do |config|
      config.complete_suite_globs "suite/**/*_test.rb"
    end
    configuration.default_complete_suite_globs("test/**/*_test.rb")

    assert_equal ["suite/**/*_test.rb"], configuration.complete_suite_globs
  ensure
    Minitest::Testmon.reset!
  end

  def test_usage_gate_accepts_the_canonical_all_suite_glob
    with_rails_command("test") do
      options = gate_options(test_files: [ALL_SUITE_GLOB])
      assert_nil Minitest.reject_testmon_usage!(options)
      assert_nil options.dig(:minitest_testmon_exit_state, :status)
    end
  end

  def test_usage_gate_still_rejects_other_test_paths
    with_rails_command("test") do
      [["test/models"], [ALL_SUITE_GLOB, "test/models_test.rb"], ["test/system"]].each do |test_files|
        options = gate_options(test_files: test_files)
        error = assert_raises(SystemExit) { Minitest.reject_testmon_usage!(options) }
        assert_equal 2, error.status, test_files.inspect
        assert_equal 2, options.dig(:minitest_testmon_exit_state, :status), test_files.inspect
      end
    end
  end

  private

  def gate_options(**overrides)
    {testmon: true, minitest_testmon_exit_state: {status: nil}}.merge(overrides)
  end

  def with_rails_command(value)
    original = ENV["MINITEST_TESTMON_RAILS_COMMAND"]
    if value
      ENV["MINITEST_TESTMON_RAILS_COMMAND"] = value
    else
      ENV.delete("MINITEST_TESTMON_RAILS_COMMAND")
    end
    capture_io { yield }
  ensure
    original ? ENV["MINITEST_TESTMON_RAILS_COMMAND"] = original : ENV.delete("MINITEST_TESTMON_RAILS_COMMAND")
  end
end
