# frozen_string_literal: true

require_relative "test_helper"

module RailsProductAcceptance
  include ProductAcceptance

  def with_rails_project(workers: 1)
    require_product!
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    runtime = MinitestTestmonAcceptance::RailsRuntime.new(project, workers:)
    require_rails_dependencies!(runtime)
    runtime.prepare
    MinitestTestmonAcceptance::RailsCliDriver.new(project)
    yield project, runtime
  ensure
    runtime&.cleanup
    project&.cleanup
  end

  def learn_rails_baseline(project, runtime, extra_env: {})
    result = driver.run(project, env: runtime.env.merge(extra_env))
    assert result.success?, "Rails baseline failed: #{result.stdout}\n#{result.stderr}"
    report = driver.report(project)
    assert_report_contract report
    assert_equal true, report.dig("publication", "published")
    MinitestTestmonAcceptance::RailsOracle.assert_auto_bundles!(report)
    report
  end

  def require_rails_dependencies!(runtime)
    return if runtime.dependencies_available?

    message = "Rails 8.1/PostgreSQL/SimpleCov acceptance dependencies unavailable"
    flunk message if ENV["REQUIRE_RAILS_ACCEPTANCE"] == "1"
    skip message
  end

  def assert_selected_includes(report, fragment)
    test_id = find_test_id(report, fragment)
    assert_includes report.dig("tests", "selected"), test_id
    test_id
  end

  def wait_for(message, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end
end
