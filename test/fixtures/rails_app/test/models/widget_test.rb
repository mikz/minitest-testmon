# frozen_string_literal: true

require_relative "../test_helper"

class WidgetTest < ActiveSupport::TestCase
  fixtures :widgets

  def test_declared_fixture
    assert_equal ENV.fetch("EXPECTED_FIXTURE", "Fixture widget v1"), widgets(:one).name
  end
end
