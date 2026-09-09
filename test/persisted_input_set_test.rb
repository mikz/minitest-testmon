# frozen_string_literal: true

require_relative "test_helper"

class PersistedInputSetTest < TestmonTestCase
  def test_canonical_order_and_every_persisted_field
    original = Minitest::Testmon::Input.new(provider: "provider", key: "key", facet: "content",
      root: "project", relative_path: "file", scope: :suite,
      fingerprint: Minitest::Testmon::Fingerprint.known("digest"))
    other = original.with(key: "another")
    assert_equal set([original, other]).id, set([other, original]).id
    changes = {provider: "other", key: "other", facet: "other", root: nil,
               relative_path: nil, scope: :test,
               fingerprint: Minitest::Testmon::Fingerprint.known("other")}
    changes.each do |field, value|
      refute_equal set([original]).id, set([original.with(**{field => value})]).id, field.to_s
    end
    missing = original.with(fingerprint: Minitest::Testmon::Fingerprint.new(state: :missing, digest: "digest", reason: :nonexistent))
    refute_equal set([original]).id, set([missing]).id
    assert_equal ["provider", "key", "content", "project", "file", "digest", "suite", "known"], set([original]).rows.first
  end

  def test_equal_values_have_the_same_id_regardless_of_string_sharing
    shared = +"same"
    first = Minitest::Testmon::Input.new(provider: shared, key: "key", facet: shared,
      root: shared, relative_path: shared, scope: :suite,
      fingerprint: Minitest::Testmon::Fingerprint.known(shared))
    second = Minitest::Testmon::Input.new(provider: +"same", key: +"key", facet: +"same",
      root: +"same", relative_path: +"same", scope: :suite,
      fingerprint: Minitest::Testmon::Fingerprint.known(+"same"))
    assert_equal first, second
    refute_same first.provider, second.provider
    assert_equal set([first]).rows, set([second]).rows
    assert_equal set([first]).id, set([second]).id
  end

  private

  def set(inputs)
    Minitest::Testmon::PersistedInputSet.new(inputs)
  end
end
