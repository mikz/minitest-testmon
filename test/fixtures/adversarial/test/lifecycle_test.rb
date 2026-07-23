# frozen_string_literal: true

require_relative "test_helper"

class BackgroundBoundaryTest < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_01_starts_delayed_background_read
    assert_equal ENV.fetch("EXPECTED_BACKGROUND_TRIGGER", "trigger-v1\n"),
      adversarial_read("data/background_trigger.txt")
    return unless ENV["ADVERSARIAL_BACKGROUND_BOUNDARY"] == "1"

    ready = ADVERSARIAL_ROOT.join("tmp/background-ready")
    release = ADVERSARIAL_ROOT.join("tmp/background-release")
    ready.dirname.mkpath
    self.class.background_thread = Thread.new do
      ready.write(Thread.current.object_id.to_s)
      Thread.pass until release.exist?
      adversarial_read("data/background.txt")
    end
    Thread.pass until ready.exist?
  end

  def test_02_releases_delayed_background_read
    assert_equal ENV.fetch("EXPECTED_BACKGROUND_TRIGGER", "trigger-v1\n"),
      adversarial_read("data/background_trigger.txt")
    return unless ENV["ADVERSARIAL_BACKGROUND_BOUNDARY"] == "1"

    ADVERSARIAL_ROOT.join("tmp/background-release").write("release")
    self.class.background_thread.join(10) || raise("background thread did not finish")
  ensure
    self.class.background_thread = nil
  end

  class << self
    attr_accessor :background_thread
  end
end

class SkipSelectedTest < Minitest::Test
  def test_selected_input
    skip "planted selected skip" if ENV["ADVERSARIAL_SKIP_SELECTED"] == "1"
    assert_equal ENV.fetch("EXPECTED_SKIP", "skip-v1\n"), adversarial_read("data/skip.txt")
  end
end

class SuiteScopedTest < Minitest::Test
  def test_suite_input
    assert_equal ENV.fetch("EXPECTED_SUITE", "suite-v1\n"), adversarial_read("data/suite.txt")
  end
end

class OverlappingProviderTest < Minitest::Test
  def test_overlap_input
    assert_equal "overlap-v1\n", adversarial_read("data/overlap.txt")
  end
end

class AtomicReportTest < Minitest::Test
  def test_atomic_input
    assert_equal ENV.fetch("EXPECTED_ATOMIC", "atomic-v1\n"), adversarial_read("data/atomic.txt")
    ready_value = ENV["ADVERSARIAL_ATOMIC_READY"]
    release_value = ENV["ADVERSARIAL_ATOMIC_RELEASE"]
    return unless ready_value && release_value

    ready = Pathname.new(ready_value)
    release = Pathname.new(release_value)
    ready.dirname.mkpath
    ready.write(Process.pid.to_s)
    Thread.pass until release.exist?
  end
end

class IncompleteDiscoveryTest < Minitest::Test
  def test_planted_failure_with_uncovered_input
    return pass unless ENV["ADVERSARIAL_INCOMPLETE_DISCOVERY"] == "1"

    # standard:disable Style/FileRead
    File.open(ADVERSARIAL_ROOT.join("uncovered.txt"), "r", &:read)
    # standard:enable Style/FileRead
    flunk "planted incomplete discovery"
  end
end

class NativeParallelTest < Minitest::Test
  parallelize_me! if ENV["ADVERSARIAL_NATIVE_PARALLEL"] == "1"

  def test_native_parallel_marker
    marker = ENV["ADVERSARIAL_NATIVE_PARALLEL_MARKER"]
    Pathname.new(marker).write("executed") if marker
    pass
  end
end
