# frozen_string_literal: true

require_relative "../test_helper"

class ManualFixtureTest < ActiveSupport::TestCase
  def test_manual_fixture_load
    ActiveRecord::FixtureSet.reset_cache
    ActiveRecord::FixtureSet.create_fixtures(
      Rails.root.join("test/manual_fixtures"),
      "manual_widgets",
      {"manual_widgets" => Widget}
    )
    widget = Widget.find_by!("name LIKE ?", "Manual%")
    assert_equal ENV.fetch("EXPECTED_MANUAL_FIXTURE", "Manual fixture widget v1"), widget.name
  ensure
    ActiveRecord::FixtureSet.reset_cache
  end
end
