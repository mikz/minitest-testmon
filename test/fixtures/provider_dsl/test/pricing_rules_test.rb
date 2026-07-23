# frozen_string_literal: true

require_relative "test_helper"

class PricingRulesTest < Minitest::Test
  def test_basic_rule
    rule = PolicyLoader.load(ROOT.join("config/pricing/basic.yml").to_s)
    assert_equal Integer(ENV.fetch("EXPECTED_BASIC_PRICE", "10")), rule.fetch("price")
  end

  def test_premium_rule
    rule = PolicyLoader.load(ROOT.join("config/pricing/premium.yaml").to_s)
    assert_equal Integer(ENV.fetch("EXPECTED_PREMIUM_PRICE", "20")), rule.fetch("price")
  end
end
