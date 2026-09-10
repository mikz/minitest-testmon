# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class ActionCableContextIsolationTest < TestmonTestCase
  def test_adapter_callback_contracts_in_a_separate_rails_process
    with_project do |project|
      output, status = Open3.capture2e(
        {"MINITEST_TESTMON" => "1", "MINITEST_TESTMON_DB" => File.join(project, "cache.sqlite3")},
        RbConfig.ruby, "-Ilib:test", "-rminitest/testmon_plugin",
        File.join(__dir__, "support/action_cable_context_cases.rb")
      )
      assert status.success?, output
      assert_match(/3 runs, .*0 failures, 0 errors/, output)
    end
  end
end
