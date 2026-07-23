# frozen_string_literal: true

require_relative "../test_helper"

class GreetingViewLookupTest < ActionView::TestCase
  def test_optional_template_membership
    expected = ENV["EXPECT_OPTIONAL_TEMPLATE"] == "1"
    assert_equal expected, lookup_context.exists?("greetings/optional")
  end
end
