# frozen_string_literal: true

require_relative "test_helper"

class DiscoveryReportTest < TestmonTestCase
  def test_frozen_shape_and_claim_keys_are_deterministic
    fingerprint = Minitest::Testmon::Fingerprint.known("abc")
    artifact = Minitest::Testmon::Artifact.new(
      key: "artifact-key",
      provider: :core,
      root: :project,
      relative_path: "lib/example.rb",
      facet: "content",
      fingerprint: fingerprint,
      members: [],
      scope: :test,
      test_ids: ["ExampleTest#test_value"],
      reason: nil,
      identity: nil
    )
    observation = Minitest::Testmon::Observation.build(
      kind: :file_read,
      path: "/project/lib/example.rb",
      operation: :read,
      test_id: "ExampleTest#test_value",
      callsite: {path: "project:test/example_test.rb", line: 7, owner: "ExampleTest"}
    )
    report = Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      mode: :run,
      bundles: ["core@1"],
      tests: {discovered: ["B", "A"], selected: ["A"], executed: ["A"]},
      observations: [observation],
      artifacts: [artifact],
      dependencies: [Minitest::Testmon::Dependency.new(test_id: "A", artifact_key: artifact.key, provider: :core, complete: true)],
      observation_claims: {observation.key => [artifact.key]}
    ).published(4)

    expected_keys = %i[schema_version mode complete ready diagnostics generation context_signature bundles tests observations inventory suggestions publication checkpoints]
    assert_equal expected_keys.sort, report.to_h.keys.sort
    assert_equal true, report.to_h.fetch(:complete)
    assert_empty report.to_h.fetch(:diagnostics)
    assert_equal %i[claimed ignored uncovered unresolved], report.to_h[:observations].keys
    assert_equal %i[claimed suite_scoped verified_empty unresolved], report.to_h[:inventory].keys
    assert_equal "artifact-key", report.to_h.dig(:observations, :claimed, :items, 0, :key)
    assert_equal "artifact-key", report.to_h.dig(:inventory, :claimed, :items, 0, :key)
    assert_equal({path: "project:test/example_test.rb", line: 7, owner: "ExampleTest"}, report.to_h.dig(:observations, :claimed, :items, 0, :callsite))
    assert report.ready?
    assert_equal report.to_json, report.to_json
  end

  def test_incompleteness_and_diagnostics_are_exposed
    report = Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      diagnostics: %i[source_drift late_activation source_drift]
    )

    assert_equal false, report.to_h.fetch(:complete)
    assert_equal %w[late_activation source_drift], report.to_h.fetch(:diagnostics)
  end

  def test_suite_dependency_is_reported_only_as_suite_scoped
    fingerprint = Minitest::Testmon::Fingerprint.known("suite")
    artifact = Minitest::Testmon::Artifact.new(
      key: "suite-key", provider: :suite, root: :project, relative_path: "config/app.yml",
      facet: "content", fingerprint: fingerprint, members: [], scope: :suite,
      test_ids: [], reason: nil, identity: nil
    )
    report = Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      artifacts: [artifact],
      dependencies: [
        Minitest::Testmon::Dependency.new(
          test_id: "*", artifact_key: artifact.key, provider: :suite, complete: true
        )
      ]
    )

    assert_equal ["suite-key"], report.to_h.dig(:inventory, :suite_scoped, :items).map { |item| item.fetch(:key) }
    assert_empty report.to_h.dig(:inventory, :claimed, :items)
  end

  def test_category_order_uses_provider_and_content_to_break_equal_key_ties
    report = Minitest::Testmon::DiscoveryReport.new(context_signature: "context")
    items = [
      {key: "shared", provider: "zeta", operation: "read"},
      {key: "shared", provider: "alpha", operation: "read"}
    ]

    expected = report.send(:category, items).fetch(:items)
    assert_equal expected, report.send(:category, items.reverse).fetch(:items)
    assert_equal %w[alpha zeta], expected.map { |item| item.fetch(:provider) }
  end

  def test_deduplicates_only_fully_equal_observations
    existing = Minitest::Testmon::Observation.build(
      kind: :file_read,
      path: "/project/config/rules.yml",
      operation: :read,
      exists_at_observation: true
    )
    missing = existing.with(exists_at_observation: false)
    assert_equal existing.key, missing.key

    report = Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      observations: Array.new(20_000, existing) + Array.new(20_000, missing)
    )

    assert_equal [existing, missing], report.observations
  end
end
