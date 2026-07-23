# frozen_string_literal: true

require "json"
require "minitest/reporters"
require "minitest/minitest_reporter_plugin"
require_relative "public_api_snapshot"

module ReporterCompat
  EXPECTED_VERSION = Gem::Version.new("1.7.1")

  class LifecycleReporter < Minitest::Reporters::BaseReporter
    def initialize(reporter_name)
      @reporter_name = reporter_name
      super()
    end

    def start
      super
      ReporterCompat.record_callback(@reporter_name, "start")
    end

    def record(result)
      super
      klass = result.respond_to?(:klass) ? result.klass : result.class.name
      ReporterCompat.record_callback(
        @reporter_name,
        "record",
        "test_id" => "#{klass}##{result.name}"
      )
    end

    def report
      super
      ReporterCompat.record_callback(@reporter_name, "report")
    end
  end

  module_function

  def configure!(custom_delegate_target: false)
    requested = custom_delegate_target ? :custom_delegate_target : :standard
    if defined?(@configuration)
      raise "reporters reconfigured from #{@configuration} to #{requested}" unless @configuration == requested
      return
    end

    assert_supported_version!
    Minitest.load(:minitest_reporter) unless Minitest.extensions.include?("minitest_reporter")
    reporters = [LifecycleReporter.new("lifecycle")]
    reporters << LifecycleReporter.new("custom_delegate_target") if custom_delegate_target
    Minitest::Reporters.use!(reporters)
    @configuration = requested
  end

  def configured?
    defined?(@configuration) && @configuration
  end

  def assert_supported_version!
    actual = Gem::Version.new(Minitest::Reporters::VERSION)
    return if actual == EXPECTED_VERSION

    raise "reporter compatibility fixture requires minitest-reporters #{EXPECTED_VERSION}, got #{actual}"
  end

  def record_boot(event, attributes = {})
    append_json(
      ENV["REPORTER_BOOT_MARKER"],
      {"event" => event, "pid" => Process.pid}.merge(attributes)
    )
  end

  def record_callback(reporter, event, attributes = {})
    append_json(
      ENV["REPORTER_CALLBACK_MARKER"],
      {"reporter" => reporter, "event" => event, "pid" => Process.pid}.merge(attributes)
    )
  end

  def append_json(path, object)
    return unless path

    destination = Pathname(path)
    destination.dirname.mkpath
    File.open(destination, "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts(JSON.generate(object))
    end
  end
  private_class_method :append_json
end
