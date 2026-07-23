# frozen_string_literal: true

require_relative "test_helper"

class RaceInputTest < Minitest::Test
  def test_content_input
    assert_equal ENV.fetch("EXPECTED_CONTENT_TRIGGER", "trigger-v1\n"),
      adversarial_read("data/content_trigger.txt")
    wait_in_selection_gap("content")
    assert_equal ENV.fetch("EXPECTED_CONTENT", "content-v1\n"), adversarial_read("data/content.txt")
    ADVERSARIAL_ROOT.join("data/content.txt").write("content-v2\n") if ENV["ADVERSARIAL_MUTATE_DURING"] == "content"
  end

  def test_catalog_membership
    assert_equal ENV.fetch("EXPECTED_MEMBERSHIP_TRIGGER", "trigger-v1\n"),
      adversarial_read("data/membership_trigger.txt")
    wait_in_selection_gap("membership")
    expected = ENV.fetch("EXPECTED_CATALOG", "one.txt")
    expected_entries = expected.empty? ? [] : expected.split(",")
    assert_equal expected_entries, AdversarialLoader.entries(ADVERSARIAL_ROOT.join("catalog").to_s)
    if ENV["ADVERSARIAL_MUTATE_DURING"] == "membership"
      ADVERSARIAL_ROOT.join("catalog/two.txt").write("two\n")
    end
  end

  def test_symlink_input
    assert_equal ENV.fetch("EXPECTED_SYMLINK_TRIGGER", "trigger-v1\n"),
      adversarial_read("data/symlink_trigger.txt")
    wait_in_selection_gap("symlink")
    assert_equal ENV.fetch("EXPECTED_SYMLINK", "symlink-v1\n"), adversarial_read("data/symlink.txt")
    replace_symlink_target("symlink_target_b.txt") if ENV["ADVERSARIAL_MUTATE_DURING"] == "symlink"
  end
end
