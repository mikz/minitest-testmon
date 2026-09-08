# frozen_string_literal: true

require_relative "test_helper"

class HarnessSelfTest < Minitest::Test
  def test_full_discovery_oracle_detects_filtering
    report = {"tests" => {"discovered" => %w[a b], "executed" => ["a"]}}

    error = assert_raises(MinitestTestmonAcceptance::Golden::Mismatch) do
      MinitestTestmonAcceptance::Golden.assert_full_discovery!(report)
    end
    assert_match "filtered", error.message
  end

  def test_selection_oracle_detects_an_omitted_impacted_test
    report = {"tests" => {"selected" => ["test:a"]}}

    error = assert_raises(MinitestTestmonAcceptance::Golden::Mismatch) do
      MinitestTestmonAcceptance::Golden.assert_selection_sound!(report, %w[test:a test:b])
    end
    assert_match "test:b", error.message
  end

  def test_contract_rejects_count_mismatch_before_product_exists
    report = minimal_report
    report["observations"]["claimed"] = {"count" => 1, "items" => []}

    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "count mismatch", error.message
  end

  def test_contract_rejects_schema_v1
    report = minimal_report.merge("schema_version" => 1)

    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "must equal 3", error.message
  end

  def test_contract_rejects_extra_keys_in_prior_v1_objects
    report = minimal_report
    report["tests"]["filtered"] = []

    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "extra", error.message
  end

  def test_contract_rejects_unknown_or_unsorted_structured_suggestions
    report = minimal_report
    report["suggestions"] = [
      {"code" => "path_set_churn", "path" => "templates", "event" => nil, "ruby" => nil},
      {"code" => "outside_root", "path" => nil, "event" => "file_read", "ruby" => nil}
    ]

    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "sorted", error.message

    report["suggestions"] = [
      {"code" => "invented", "path" => nil, "event" => nil, "ruby" => nil}
    ]
    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "uncovered_file", error.message
  end

  def test_contract_rejects_inconsistent_completeness_fields
    report = minimal_report.merge(
      "complete" => true,
      "diagnostics" => ["source_drift"]
    )
    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "cannot contain diagnostics", error.message

    report = minimal_report.merge("ready" => true)
    error = assert_raises(MinitestTestmonAcceptance::ReportContract::Violation) do
      MinitestTestmonAcceptance::ReportContract.validate!(report)
    end
    assert_match "ready must equal", error.message

    assert MinitestTestmonAcceptance::ReportContract.validate!(minimal_report)
  end

  private

  def minimal_report
    categories = ->(keys) { keys.to_h { |key| [key, {"count" => 0, "items" => []}] } }
    {
      "schema_version" => 3,
      "checkpoints" => {"count" => 0, "accepted_ids" => [], "stop_reason" => nil},
      "mode" => "run",
      "complete" => false,
      "ready" => false,
      "diagnostics" => [],
      "generation" => nil,
      "context_signature" => "context",
      "bundles" => [],
      "tests" => {"discovered" => [], "selected" => [], "executed" => []},
      "observations" => categories.call(MinitestTestmonAcceptance::ReportContract::OBSERVATION_KEYS),
      "inventory" => categories.call(MinitestTestmonAcceptance::ReportContract::INVENTORY_KEYS),
      "suggestions" => [],
      "publication" => {"published" => false, "reason" => nil}
    }
  end
end
