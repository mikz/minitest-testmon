# frozen_string_literal: true

require_relative "test_helper"

module ProviderProductAcceptance
  include ProductAcceptance

  CUSTOM_PROVIDER_IDS = %w[
    documents@1 fileset.compat_paths@1 fileset.compat_templates@1
    pricing_rules@1 resolver_inputs@1 ruby_compatibility@1
    shared_configuration@1 template_catalog@1
  ].freeze

  def with_provider_project
    require_product!
    project = MinitestTestmonAcceptance::Project.copy_fixture("provider_dsl")
    yield project
  ensure
    project&.cleanup
  end

  def learn_provider_baseline(project, extra_env: {})
    result = driver.run(project, env: extra_env)
    assert result.success?, "provider baseline failed: #{result.stdout}\n#{result.stderr}"
    report = driver.report(project)
    assert_report_contract report
    assert_equal true, report.fetch("ready")
    assert_equal true, report.dig("publication", "published")
    assert_includes report.fetch("bundles"), "ruby@1"
    CUSTOM_PROVIDER_IDS.each { |provider_id| assert_includes report.fetch("bundles"), provider_id }
    report
  end

  def run_provider(project, extra_env: {})
    result = driver.run(project, env: extra_env)
    report = driver.report(project)
    assert_report_contract report
    [result, report]
  end

  def observation_items(report, category = nil)
    categories = category ? [category.to_s] : MinitestTestmonAcceptance::ReportContract::OBSERVATION_KEYS
    categories.flat_map { |name| report.dig("observations", name, "items") }
  end

  def inventory_items(report, category = nil)
    categories = category ? [category.to_s] : MinitestTestmonAcceptance::ReportContract::INVENTORY_KEYS
    categories.flat_map { |name| report.dig("inventory", name, "items") }
  end

  def assert_observation_reason(report, reason)
    matches = observation_items(report).select { |item| item.fetch("reason") == reason }
    refute_empty matches, "missing observation reason #{reason.inspect}"
    matches
  end

  def assert_only_provider_test(report, fragment)
    test_id = find_test_id(report, fragment)
    assert_equal [test_id], report.dig("tests", "selected")
    assert_equal [test_id], report.dig("tests", "executed")
    test_id
  end

  def configuration_source(body)
    indented = body.lines.map { |line| "  #{line}" }.join
    <<~RUBY
      # frozen_string_literal: true

      require "minitest/testmon"

      Minitest::Testmon.configure do |config|
      #{indented}end
    RUBY
  end
end
