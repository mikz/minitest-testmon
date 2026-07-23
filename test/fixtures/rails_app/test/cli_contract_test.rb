# frozen_string_literal: true

require_relative "test_helper"

class CliContractTest < ActiveSupport::TestCase
  def test_controlled_failure
    flunk "controlled Rails CLI failure" if ENV["RAILS_ACCEPTANCE_FAIL_TEST"] == "1"

    assert true
  end

  def test_permanent_skip_alpha
    if ENV["RAILS_ACCEPTANCE_PERMANENT_SKIP"] == "1"
      order = Pathname(ENV.fetch("RAILS_ACCEPTANCE_SKIP_ORDER_DIR"))
      ready = order.join("omega-ready")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until ready.exist?
        raise "omega permanent skip did not run" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        Thread.pass
      end
      record_permanent_skip_order(order)
      skip "permanent Rails CLI alpha skip"
    end

    assert true
  end

  def test_permanent_skip_omega
    if ENV["RAILS_ACCEPTANCE_PERMANENT_SKIP"] == "1"
      order = Pathname(ENV.fetch("RAILS_ACCEPTANCE_SKIP_ORDER_DIR"))
      order.mkpath
      record_permanent_skip_order(order)
      order.join("omega-ready").write("ready")
      skip "permanent Rails CLI omega skip"
    end

    assert true
  end

  private

  def record_permanent_skip_order(order)
    File.open(order.join("outcomes"), File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
      file.write("#{self.class}##{name}\n")
    end
  end
end
