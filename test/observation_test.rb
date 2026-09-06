# frozen_string_literal: true

require_relative "test_helper"

class ObservationTest < TestmonTestCase
  def test_unicode_identifiers_can_be_combined_with_binary_coverage_details
    observation = Minitest::Testmon::Observation.build(
      kind: :coverage_lines,
      provider: :"ruby@1",
      path: "/project/účty.rb",
      test_id: "AccountTest#test_Potkáme_email_verification",
      callsite: "/project/test/účty_test.rb:300",
      details: {lines: [128, 300]}
    )

    assert_equal "AccountTest#test_Potkáme_email_verification", observation.test_id
    assert_equal "/project/účty.rb", observation.path
    assert_match(/\A[0-9a-f]{64}\z/, observation.key)
  end

  def test_identity_is_canonical_and_preserves_field_boundaries
    build = ->(path, test_id, details) {
      Minitest::Testmon::Observation.build(kind: :coverage_lines, path:, test_id:, details:)
    }

    first = build.call("a", "b\0c", {lines: [300], label: "Příliš"})
    reordered = build.call("a", "b\0c", {label: "Příliš", lines: [300]})
    shifted = build.call("a\0b", "c", {lines: [300], label: "Příliš"})

    assert_equal first.key, reordered.key
    refute_equal first.key, shifted.key
  end
end
