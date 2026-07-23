# frozen_string_literal: true

require_relative "test_helper"

class CustomProviderTest < ActiveSupport::TestCase
  def test_tracepoint_policy_loader
    policy = RailsPolicyLoader.load(Rails.root.join("config/policies/rules.yml").to_s)
    skip "newly skipped policy consumer" if ENV["RAILS_ACCEPTANCE_SKIP_POLICY_TEST"] == "1"

    assert_equal ENV.fetch("EXPECTED_POLICY_MODE", "v1"), policy.fetch("mode")
  end

  def test_notification_policy_loader
    path = Rails.root.join("config/policies/rules.yml")
    policy = ActiveSupport::Notifications.instrument("render.rails_policy", identifier: path.to_s) do
      YAML.safe_load_file(path)
    end
    assert_equal ENV.fetch("EXPECTED_POLICY_MODE", "v1"), policy.fetch("mode")
  end
end
