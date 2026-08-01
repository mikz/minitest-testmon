# frozen_string_literal: true

require_relative "test_helper"

class ReportContractTest < Minitest::Test
  include ProductAcceptance

  def test_discovery_emits_the_frozen_public_report_shape
    require_product!

    with_project("discovery") do |project|
      result = driver.run(project, full: true)
      refute result.success?, "incomplete discovery unexpectedly exited zero"

      report = driver.report(project)
      assert_report_contract report
      assert_equal "run", report.fetch("mode")
      assert_equal false, report.fetch("ready")
      assert_equal false, report.dig("publication", "published")
      assert_nil report.fetch("generation")
    end
  end
end
