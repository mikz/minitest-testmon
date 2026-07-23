# frozen_string_literal: true

require_relative "test_helper"

class ReporterCompatibilityTest < ActiveSupport::TestCase
  def test_custom_yaml_dependency_through_parallel_worker
    test_id = "#{self.class}##{name}"
    marker = Pathname(ENV.fetch("REPORTER_APP_MARKER"))
    marker.dirname.mkpath
    File.open(marker, "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts("#{Process.pid}:#{test_id}")
    end

    path = Rails.root.join("config/policies/rules.yml")
    policy = RailsPolicyLoader.load(path.to_s)
    ActiveSupport::Notifications.instrument("render.rails_policy", identifier: path.to_s) do
      assert_equal ENV.fetch("EXPECTED_POLICY_MODE", "v1"), policy.fetch("mode")
    end
  end
end
