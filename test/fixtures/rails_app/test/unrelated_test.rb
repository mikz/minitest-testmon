# frozen_string_literal: true

require_relative "test_helper"

class UnrelatedTest < ActiveSupport::TestCase
  if ENV["RAILS_ACCEPTANCE_PARALLELIZE_ME"] == "1"
    parent_marker = Pathname(ENV.fetch("RAILS_ACCEPTANCE_PARALLEL_PARENT_MARKER"))
    parent_marker.dirname.mkpath
    parent_marker.write(Process.pid)
    parallelize_me!
  end

  def test_unrelated
    assert_equal 4, 2 + 2
  end
end
