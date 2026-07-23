# frozen_string_literal: true

require "minitest"
require "minitest/testmon" if ENV["MINITEST_TESTMON"] == "1"

module Minitest
  register_plugin :testmon unless extensions.include?(:testmon) || extensions.include?("testmon")

  def self.plugin_testmon_options(parser, options)
    return if options[:minitest_testmon_options_registered]

    options[:minitest_testmon_options_registered] = true
    options[:minitest_testmon_exit_state] = {status: nil}
    Minitest.after_run do
      status = options.dig(:minitest_testmon_exit_state, :status)
      raise SystemExit.new(status) if status
    end
    options[:testmon] ||= ENV["MINITEST_TESTMON"] == "1"
    parser.on("--testmon[=VALUE]", "Enable minitest-testmon") do |value|
      options[:testmon_explicit] = true
      if value
        options[:testmon_usage_error] = "--testmon does not accept a value"
      else
        options[:testmon] = true
      end
    end
    parser.on("--testmon-db [PATH]", "Use a specific testmon SQLite database") do |path|
      options[:testmon_database_given] = true
      path ? options[:testmon_database] = path : options[:testmon_usage_error] = "--testmon-db requires PATH"
    end
    parser.on("--testmon-report [PATH]", "Write deterministic discovery evidence") do |path|
      options[:testmon_report_given] = true
      path ? options[:testmon_report] = path : options[:testmon_usage_error] = "--testmon-report requires PATH"
    end
    parser.on_tail do
      extensions.delete_if { |extension| extension.to_s == "testmon" }
      register_plugin :testmon
    end
  end

  def self.plugin_testmon_init(options)
    reject_testmon_usage!(options)
    return unless options[:testmon]
    return if options[:minitest_testmon_initialized]

    require "minitest/testmon" unless defined?(Minitest::Testmon::Runtime)
    options[:minitest_testmon_initialized] = true
    if ENV["MINITEST_TESTMON_CONFIG"] && File.file?(ENV["MINITEST_TESTMON_CONFIG"])
      Testmon.load_configuration!(ENV["MINITEST_TESTMON_CONFIG"])
    end
    Testmon.configuration.database(options[:testmon_database] || ENV["MINITEST_TESTMON_DB"]) if options[:testmon_database] || ENV["MINITEST_TESTMON_DB"]
    Testmon.configuration.report(options[:testmon_report] || ENV["MINITEST_TESTMON_REPORT"]) if options[:testmon_report] || ENV["MINITEST_TESTMON_REPORT"]
    Testmon.activate_rails_8_1!
    Testmon::Runtime.new(configuration: Testmon.configuration, registry: Testmon.registry).install(options)
  rescue => error
    raise unless defined?(Testmon::Error) && error.is_a?(Testmon::Error)

    warn error.message
    exit_testmon!(options, 4)
  end

  def self.reject_testmon_usage!(options)
    auxiliary_without_activation = !options[:testmon] &&
      (options[:testmon_database_given] || options[:testmon_report_given])
    message = options[:testmon_usage_error]
    message ||= "--testmon-db/--testmon-report require --testmon" if auxiliary_without_activation
    if rails_testmon?(options)
      partial = []
      command = ENV["MINITEST_TESTMON_RAILS_COMMAND"]
      partial << "test:* task" unless %w[test t].include?(command)
      partial << "test paths" if Array(options[:test_files]).any?
      partial << "--include/--name" if options[:include]
      partial << "--exclude" if options[:exclude]
      partial << "DEFAULT_TEST" if ENV.key?("DEFAULT_TEST")
      partial << "DEFAULT_TEST_EXCLUDE" if ENV.key?("DEFAULT_TEST_EXCLUDE")
      message ||= "--testmon requires the complete default Rails test suite; remove #{partial.join(", ")}" if partial.any?
    end
    return unless message

    if defined?(Testmon) && Testmon.respond_to?(:take_early_observations)
      Testmon.take_early_observations
    end
    warn message
    exit_testmon!(options, 2)
  end

  def self.direct_rails_testmon?(options)
    options[:testmon_explicit] && ENV["MINITEST_TESTMON_RAILS_FLAG"] == "1"
  end

  def self.rails_testmon?(options)
    direct_rails_testmon?(options) ||
      (options[:testmon] && ENV["MINITEST_TESTMON_RAILS_COMMAND"] == "test")
  end

  def self.exit_testmon!(options, status)
    options.fetch(:minitest_testmon_exit_state)[:status] = status
    raise SystemExit.new(status)
  end
end
