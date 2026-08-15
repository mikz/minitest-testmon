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
end
