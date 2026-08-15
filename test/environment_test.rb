# frozen_string_literal: true

require_relative "test_helper"

class EnvironmentTest < TestmonTestCase
  def test_conventional_truthy_values_enable_testmon
    %w[1 true yes on TRUE Yes ON].each do |value|
      assert Minitest::Testmon::Environment.enabled?(value), value
    end
  end

  def test_surrounding_whitespace_is_ignored
    assert Minitest::Testmon::Environment.enabled?("  true\n")
  end

  def test_other_values_do_not_enable_testmon
    [nil, "", "0", "false", "no", "off", "enabled"].each do |value|
      refute Minitest::Testmon::Environment.enabled?(value), value.inspect
    end
  end

  def test_bypass_disables_an_enabled_environment
    previous_enabled = ENV["MINITEST_TESTMON"]
    previous_bypass = ENV[Minitest::Testmon::Environment::BYPASS_VARIABLE]
    ENV["MINITEST_TESTMON"] = "1"
    ENV[Minitest::Testmon::Environment::BYPASS_VARIABLE] = "1"

    assert Minitest::Testmon::Environment.enabled?
    assert Minitest::Testmon::Environment.bypassed?
    refute Minitest::Testmon::Environment.active?
  ensure
    previous_enabled ? ENV["MINITEST_TESTMON"] = previous_enabled : ENV.delete("MINITEST_TESTMON")
    if previous_bypass
      ENV[Minitest::Testmon::Environment::BYPASS_VARIABLE] = previous_bypass
    else
      ENV.delete(Minitest::Testmon::Environment::BYPASS_VARIABLE)
    end
  end
end
