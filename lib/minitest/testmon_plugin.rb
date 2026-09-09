# frozen_string_literal: true

require "minitest"
require "minitest/testmon/environment"
require "minitest/testmon" if Minitest::Testmon::Environment.enabled?

module Minitest
  register_plugin :testmon unless extensions.include?(:testmon) || extensions.include?("testmon")

  module TestmonLateInitialization
    def self.minitest_plugin_init(options)
      Minitest.plugin_testmon_init(options)
    end
  end

  def self.plugin_testmon_options(parser, options)
    return if options[:minitest_testmon_options_registered]

    options[:minitest_testmon_options_registered] = true
    initialize_testmon_exit_state!(options)
    options[:testmon] ||= Minitest::Testmon::Environment.enabled?
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
    parser.on_tail do
      extensions.delete_if { |extension| extension.to_s == "testmon" }
      register_plugin :testmon
    end
  end

  def self.initialize_testmon_exit_state!(options)
    return if options[:minitest_testmon_exit_state]

    options[:minitest_testmon_exit_state] = {status: nil}
    Minitest.after_run do
      status = options.dig(:minitest_testmon_exit_state, :status)
      raise SystemExit.new(status) if status
    end
  end

  def self.plugin_testmon_init(options)
    # Rails skips test:prepare for paths and names, loading the application
    # from test_helper after option parsing. Environment activation must also
    # initialize a plugin registered during that test-loading phase.
    options[:testmon] ||= Minitest::Testmon::Environment.enabled?
    initialize_testmon_exit_state!(options)
    reject_testmon_usage!(options)
    return unless options[:testmon]
    return if options[:minitest_testmon_initialized]

    # A late-loaded Rails helper can register minitest-reporters after us.
    # Minitest visits appended module plugins after its existing plugins.
    unless options[:minitest_testmon_options_registered] || options[:minitest_testmon_initialization_deferred]
      options[:minitest_testmon_initialization_deferred] = true
      register_plugin TestmonLateInitialization unless extensions.include?(TestmonLateInitialization)
      return
    end

    require "minitest/testmon" unless defined?(Minitest::Testmon::Runtime)
    options[:minitest_testmon_initialized] = true
    if ENV["MINITEST_TESTMON_CONFIG"] && File.file?(ENV["MINITEST_TESTMON_CONFIG"])
      Testmon.load_configuration!(ENV["MINITEST_TESTMON_CONFIG"])
    end
    Testmon.configuration.database(options[:testmon_database] || ENV["MINITEST_TESTMON_DB"]) if options[:testmon_database] || ENV["MINITEST_TESTMON_DB"]
    Testmon.activate_rails_8_1!
    Testmon::Runtime.new(
      configuration: Testmon.configuration,
      registry: Testmon.registry
    ).install(options)
  rescue => error
    raise unless defined?(Testmon::Error) && error.is_a?(Testmon::Error)

    warn error.message
    exit_testmon!(options, 4)
  end

  def self.reject_testmon_usage!(options)
    auxiliary_without_activation = !options[:testmon] && options[:testmon_database_given]
    message = options[:testmon_usage_error]
    message ||= "--testmon-db requires --testmon" if auxiliary_without_activation
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

  # `bin/rails test:all` reaches Minitest as the plain `test` command carrying
  # the profile's complete-suite globs (Configuration#complete_suite_globs);
  # that exact set is the only test-path shape still denoting a complete suite.
  def self.rails_all_suite_testmon?(options)
    return false unless rails_testmon?(options)
    files = Array(options[:test_files]).map(&:to_s).uniq.sort
    !files.empty? && files == Testmon.configuration.complete_suite_globs
  end

  def self.exit_testmon!(options, status)
    options.fetch(:minitest_testmon_exit_state)[:status] = status
    raise SystemExit.new(status)
  end
end
