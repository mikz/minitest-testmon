# frozen_string_literal: true

require_relative "../application_system_test_case"

class DashboardSystemTest < ApplicationSystemTestCase
  test "dashboard lists tracked widgets" do
    Widget.create!(name: "system-widget")
    visit "/dashboard"

    assert_selector "h1.dashboard", text: "Dashboard"
    assert_text(/\d+ widgets? tracked/)
  end

  test "greeting page renders for visitors" do
    visit "/greeting"

    assert_text "Greeting"
  end
end
