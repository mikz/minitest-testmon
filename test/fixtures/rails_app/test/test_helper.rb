# frozen_string_literal: true

if ENV["SIMPLECOV_ORDER"] == "after"
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    coverage_dir ENV.fetch("RAILS_ACCEPTANCE_COVERAGE_DIR")
  end
end

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "../lib/rails_policy_loader"

# These paths are intentionally registered after Rails initialization. Testmon
# must defer its built-in Rails provider snapshot until Minitest plugin init.
ActionController::Base.prepend_view_path Rails.root.join("runtime_views")
I18n.load_path << Rails.root.join("runtime_locales/en.yml").to_s

if ENV["RAILS_ACCEPTANCE_REPORTERS"] == "1"
  require "minitest/reporters"
  Minitest.load :minitest_reporter if Minitest.respond_to?(:load)
  Minitest::Reporters.use!([Minitest::Reporters::SpecReporter.new])
end

if (api_snapshot = ENV["RAILS_ACCEPTANCE_API_SNAPSHOT"])
  require_relative "support/rails_cli_api_snapshot"
  Minitest.after_run { RailsCliApiSnapshot.write(api_snapshot) }
end

if ENV["PROVIDER_DEFINITION_SNAPSHOT"]
  Minitest.after_run do
    load Rails.root.join("provider_definition_snapshot.rb")
  end
end

if (loaded_features = ENV["RAILS_ACCEPTANCE_LOADED_FEATURES"])
  Minitest.after_run do
    features = $LOADED_FEATURES.grep(%r{(?:minitest/testmon|minitest-testmon\.rb)}).sort
    Pathname(loaded_features).write(JSON.generate(features))
  end
end

parallel_workers = Integer(ENV.fetch("PARALLEL_WORKERS", "1"))
parallel_mode = ENV.fetch("PARALLEL_MODE", "processes").to_sym
ActiveSupport::TestCase.parallelize workers: parallel_workers, with: parallel_mode, threshold: 0
ActiveSupport::TestCase.fixture_paths = [
  Rails.root.join("test/fixtures"),
  Rails.root.join("test/manual_fixtures")
]

class ActiveSupport::TestCase
  setup do
    marker = ENV["RAILS_ACCEPTANCE_TEST_MARKER"]
    if marker
      marker_path = Pathname.new(marker)
      marker_path.dirname.mkpath
      File.open(marker_path, "a") { |file| file.puts "#{Process.pid}:#{self.class}##{name}" }
    end

    if ENV["MINITEST_TESTMON_BYPASS"] != "1" && ENV["RAILS_ACCEPTANCE_KILL_TEST"] == name
      Process.kill("KILL", Process.pid)
    end

    barrier = ENV["RAILS_ACCEPTANCE_BARRIER"]
    if barrier
      barrier_path = Pathname.new(barrier)
      barrier_path.mkpath
      barrier_path.join("worker-#{Process.pid}").write(name)
      release = barrier_path.join("release")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until release.exist?
        raise "worker barrier timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        Thread.pass
      end
    end
  end
end
