# frozen_string_literal: true

require_relative "test_helper"

class BootSchemaTest < ActiveSupport::TestCase
  def test_application_body_policy
    assert_equal(
      ENV.fetch("EXPECTED_APP_BODY_POLICY", "v1"),
      TestmonRailsAcceptance::Application::APP_BODY_POLICY.fetch("mode")
    )
  end

  def test_boot_input
    assert_equal "boot-v1", AcceptanceBoot::VALUE
  end

  def test_schema_input
    assert_includes Widget.column_names, "name"
  end
end
