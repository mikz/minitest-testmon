# frozen_string_literal: true

require_relative "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  if ENV["RAILS_ACCEPTANCE_BROWSER"] == "1"
    require "capybara-playwright-driver"
    driven_by :playwright, options: {
      browser_type: :chromium,
      headless: true,
      playwright_cli_executable_path: "npx --yes playwright@#{Playwright::COMPATIBLE_PLAYWRIGHT_VERSION}"
    }
  else
    driven_by :rack_test
  end
end
