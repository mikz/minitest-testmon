# frozen_string_literal: true

require_relative "test_helper"

class HighVolumeSpoolTest < ActiveSupport::TestCase
  def test_repeated_provider_observations_stream_to_worker_spool
    path = Rails.root.join("config/policies/rules.yml").to_s
    iterations = Integer(ENV.fetch("RAILS_ACCEPTANCE_HIGH_VOLUME_ITERATIONS", "1"))
    iterations.times do
      ActiveSupport::Notifications.instrument("render.rails_policy", identifier: path)
    end

    barrier_value = ENV["RAILS_ACCEPTANCE_HIGH_VOLUME_BARRIER"]
    return pass unless barrier_value

    barrier = Pathname.new(barrier_value)
    barrier.mkpath
    barrier.join("ready-#{Process.pid}").write(iterations.to_s)
    release = barrier.join("release")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    until release.exist?
      raise "high-volume spool barrier timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end
end
