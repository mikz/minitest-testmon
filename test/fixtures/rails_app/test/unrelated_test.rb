# frozen_string_literal: true

require_relative "test_helper"

class UnrelatedTest < ActiveSupport::TestCase
  def test_unrelated
    assert_equal 4, 2 + 2
  end
end
