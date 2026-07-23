# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/subject"
require_relative "../lib/top_level_fallback"

# The exact File.open call is part of the black-box acceptance contract.
# standard:disable Style/FileRead
class SelectionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_alpha
    wait_on_acceptance_lease_barrier
    assert_equal 2, Subject.alpha
  end

  def test_beta
    assert_equal 4, Subject.beta
  end

  def test_exact_file_input
    contents = File.open(File.join(ROOT, "data/exact.txt"), "r", &:read)
    assert_equal "exact-v1\n", contents
  end

  def test_string_literal
    assert_equal "literal-v1", Subject.string_literal
  end

  def test_dispatch_operand
    assert_equal "helper-one", Subject.dispatch
  end

  def test_nested_block_operand
    assert_equal [2, 4], Subject.nested_block
  end

  def test_branch_operand
    assert_equal :large, Subject.guarded(2)
  end

  def test_top_level_fallback
    assert_equal 10, TOP_LEVEL_FALLBACK_VALUE
  end

  private

  def wait_on_acceptance_lease_barrier
    ready = ENV["ACCEPTANCE_LEASE_READY"]
    release = ENV["ACCEPTANCE_LEASE_RELEASE"]
    return unless ready && release

    File.write(ready, Process.pid.to_s)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until File.exist?(release)
      raise "acceptance lease barrier timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end
end
# standard:enable Style/FileRead
