# frozen_string_literal: true

require_relative "test_helper"

class ResolverTest < Minitest::Test
  def test_resolver_claim
    input = ResolverLoader.load(ROOT.join("config/resolver/input.yml").to_s)
    assert_equal ENV.fetch("EXPECTED_RESOLVER", "resolver-v1"), input.fetch("value")
  end
end
