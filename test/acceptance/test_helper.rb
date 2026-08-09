# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "active_support"
require "active_support/test_case"

require "minitest_testmon_acceptance"

ActiveSupport::TestCase.parallelize(
  workers: 4,
  with: :processes,
  threshold: 0
)

module ProductAcceptance
  def driver
    @driver ||= MinitestTestmonAcceptance::Driver.new
  end

  def require_product!
    return if driver.available?

    message = "public minitest-testmon executable unavailable: #{driver.bin.join(" ")}"
    flunk message if ENV["REQUIRE_MINITEST_TESTMON"] == "1"
    skip message
  end

  def with_project(name)
    project = MinitestTestmonAcceptance::Project.copy_fixture(name)
    yield project
  ensure
    project&.cleanup
  end

  def assert_report_contract(report)
    assert MinitestTestmonAcceptance::ReportContract.validate!(report)
  rescue MinitestTestmonAcceptance::ReportContract::Violation => error
    flunk error.message
  end

  def find_test_id(report, fragment)
    ids = report.dig("tests", "discovered") || []
    matches = ids.grep(/#{Regexp.escape(fragment)}/)
    assert_equal 1, matches.length, "expected one test ID containing #{fragment.inspect}, got #{matches.inspect}"
    matches.first
  end

  def run_selector_disabled(project, env: {})
    Open3.capture3(env, *project.test_command, chdir: project.path.to_s)
  end
end
