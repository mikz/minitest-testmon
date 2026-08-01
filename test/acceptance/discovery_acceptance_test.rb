# frozen_string_literal: true

require_relative "test_helper"

class DiscoveryAcceptanceTest < Minitest::Test
  include ProductAcceptance

  def test_full_discovery_never_filters_even_when_a_test_fails
    require_product!

    with_project("discovery") do |project|
      result = driver.run(project, full: true, env: {"PLANT_DISCOVERY_FAILURE" => "1"})
      refute result.success?, "planted test failure unexpectedly exited zero"

      report = driver.report(project)
      assert_report_contract report
      MinitestTestmonAcceptance::Golden.assert_full_discovery!(report)
      assert_equal false, report.dig("publication", "published")
    end
  end

  def test_discovery_report_and_suggestions_are_cross_root_deterministic
    require_product!

    reports = 2.times.map do
      project = MinitestTestmonAcceptance::Project.copy_fixture("discovery")
      result = driver.run(project, full: true)
      refute result.success?, "incomplete discovery unexpectedly exited zero"
      report = driver.report(project)
      assert_equal false, report.fetch("ready")
      assert_equal false, report.dig("publication", "published")
      report
    ensure
      project&.cleanup
    end

    reports.each { |report| assert_report_contract(report) }
    digests = reports.map { |report| Digest::SHA256.hexdigest(JSON.generate(report)) }
    assert_equal digests.first, digests.last,
      "cross-root report digest mismatch; context signatures=#{reports.map { |report| report.fetch("context_signature") }.inspect}"
  end

  def test_file_new_file_open_and_write_only_construction_are_claimed
    require_product!

    with_discovery_report do |report|
      assert_observation report, :claimed,
        path: %r{data/existing\.txt\z}, kind: "file_open"
      assert_observation report, :claimed,
        path: %r{data/write-only\.txt\z}, reason: "conservative_file_construction",
        exists_at_observation: true
    end
  end

  def test_failed_nonexistent_file_open_does_not_fabricate_an_inaccessible_path
    require_product!

    with_discovery_report do |report|
      forbidden = "does-not-exist.txt"
      observation_paths = MinitestTestmonAcceptance::ReportContract::OBSERVATION_KEYS.flat_map do |category|
        report.dig("observations", category, "items").filter_map { |item| item.fetch("path") }
      end
      inventory_paths = MinitestTestmonAcceptance::ReportContract::INVENTORY_KEYS.flat_map do |category|
        report.dig("inventory", category, "items").filter_map { |item| item.fetch("path") }
      end

      refute observation_paths.any? { |path| path.end_with?(forbidden) },
        "observer fabricated failed File.open arguments that C-call observation cannot access"
      refute inventory_paths.any? { |path| path.end_with?(forbidden) },
        "inventory fabricated a missing candidate without a provider declaration"
      refute_includes JSON.generate(report.fetch("suggestions")), forbidden,
        "suggestions fabricated a missing path without a provider declaration"
    end
  end

  def test_disappearing_file_is_a_source_race_not_nonexistent
    require_product!

    with_discovery_report do |report|
      assert_observation report, :unresolved,
        path: %r{data/racy\.txt\z}, reason: "source_race"
    end
  end

  def test_direct_c_file_read_is_opaque_and_unresolved
    require_product!

    with_discovery_report do |report|
      assert_observation report, :unresolved,
        kind: "file_read", reason: "opaque_c_call"
    end
  end

  def test_ruby_require_and_load_arguments_are_observed
    require_product!

    with_discovery_report do |report|
      assert_observation report, :claimed,
        path: %r{lib/loaded_feature\.rb\z}, operation: /require/
      assert_observation report, :claimed,
        path: %r{lib/reloaded_feature\.rb\z}, operation: "load"
    end
  end

  def test_every_claimed_observation_resolves_to_provider_inventory
    require_product!

    with_discovery_report do |report|
      MinitestTestmonAcceptance::Golden.assert_inventory_claims_resolve!(report)
    end
  end

  private

  def assert_observation(report, category, **expected)
    assert MinitestTestmonAcceptance::Golden.assert_observation!(report, category:, **expected)
  rescue MinitestTestmonAcceptance::Golden::Mismatch => error
    flunk error.message
  end

  def with_discovery_report
    with_project("discovery") do |project|
      result = driver.run(project, full: true)
      refute result.success?, "source-race/opaque discovery unexpectedly exited zero"
      report = driver.report(project)
      assert_report_contract report
      assert_equal false, report.fetch("ready"),
        "source-race and opaque C observations must prevent readiness"
      assert_nil report.fetch("generation")
      assert_equal false, report.dig("publication", "published")
      yield report
    end
  end
end
