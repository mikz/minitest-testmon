# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "minitest/testmon_plugin"

METRICS = Hash.new(0.0)
module MeasureTestBody
  def run
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    METRICS["test_body_s"] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end
Minitest::Test.prepend(MeasureTestBody)

if ENV.fetch("MINITEST_TESTMON") == "1"
  raise "build the native extension with bundle exec rake compile" unless defined?(Minitest::Testmon::NativeTracePoint)
  METRICS["native_filter"] = true
  [Minitest::Testmon::Runtime, Minitest::Testmon::RuntimeReporter].zip([[:install, :flush_checkpoints], [:report]]).each do |type, names|
    wrapper = Module.new
    names.each do |name|
      wrapper.define_method(name) do |*args, **kwargs, &block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super(*args, **kwargs, &block)
      ensure
        METRICS["#{name}_s"] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
    end
    type.prepend(wrapper)
  end
end

Dir["lib/**/*.rb"].sort.each { |path| require File.expand_path(path) }
CONFIG_TOTAL = Dir["config/*.json"].sort.sum { |path| JSON.parse(File.read(path)).fetch("weight") } if ENV["DETERMINISTIC_CONFIG_TOTAL"]
Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }
Minitest.after_run do
  times = Process.times
  METRICS["process_cpu_s"] = times.utime + times.stime
  File.write(ENV.fetch("DETERMINISTIC_METRICS"), JSON.pretty_generate(METRICS))
end
