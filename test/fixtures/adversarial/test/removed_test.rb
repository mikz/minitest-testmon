# frozen_string_literal: true

require_relative "test_helper"

class RemovedTest < Minitest::Test
  def test_removed_input
    assert_equal ENV.fetch("EXPECTED_REMOVED", "removed-v1\n"), adversarial_read("data/removed.txt")
    flunk "planted failure before removal" if ENV["ADVERSARIAL_FAIL_REMOVED"] == "1"
  end
end
