# frozen_string_literal: true

require_relative "environment"

module Minitest
  module Testmon
    module RailsBootstrap
      DIRECT_FLAG = "--testmon"
      DIRECT_ENV = "MINITEST_TESTMON_RAILS_FLAG"
      COMMAND_ENV = "MINITEST_TESTMON_RAILS_COMMAND"
      PROJECT_ROOT_ENV = "MINITEST_TESTMON_PROJECT_ROOT"
      FULL_SUITE_MESSAGE = "--testmon requires a complete Rails test suite (bin/rails test or bin/rails test:all)"
      PROJECT_ROOT_MESSAGE = "Testmon :project must remain the canonical Rails application root"

      module_function

      def preload(arguments, application_root:)
        argv = Array(arguments).map(&:to_s)
        # Auxiliary options must load the plugin so it can report a usage
        # error, but they do not activate Testmon and therefore must not enter
        # the early-observation path before the main module is loaded.
        return false unless Environment.enabled? || argv.include?(DIRECT_FLAG)

        ENV["MINITEST_TESTMON"] = "1" if argv.include?(DIRECT_FLAG)
        root = File.realpath(application_root.to_s)
        ENV[PROJECT_ROOT_ENV] = root
        select_project_configuration(root)
        load_plugin!
        verify_project_root!(root)
        true
      end

      def call(arguments, application_root:, test_command:, rake_test_prepare:)
        argv = Array(arguments).map(&:to_s)
        option_request = argv.any? { |argument| argument.start_with?("--testmon") }
        environment_request = Environment.enabled?
        return false unless option_request || environment_request

        test_command = !!test_command
        test_preparation = test_command && rake_test_prepare
        unless test_preparation
          reject_usage!("#{FULL_SUITE_MESSAGE}; use bin/rails test --testmon") if option_request
          return false
        end

        $stdout.sync = true if argv.any? { |argument| argument == "-h" || argument == "--help" }

        direct = argv.include?(DIRECT_FLAG)
        if direct
          reject_usage!("#{FULL_SUITE_MESSAGE}; remove Rails environment options") if environment_option?(argv)
          ENV["MINITEST_TESTMON"] = "1"
          ENV[DIRECT_ENV] = "1"
        end
        if direct || environment_request
          ENV[COMMAND_ENV] = "test"
          root = File.realpath(application_root.to_s)
          ENV[PROJECT_ROOT_ENV] = root
          select_project_configuration(root)
        end

        load_plugin!
        verify_project_root!(root) if direct || environment_request
        true
      end

      def requested?(arguments)
        Environment.enabled? ||
          Array(arguments).any? { |argument| argument.to_s.start_with?("--testmon") }
      end

      def rake_test_prepare?
        return false unless defined?(Rake) && Rake.respond_to?(:application)

        Array(Rake.application.top_level_tasks) == ["test:prepare"]
      end

      def environment_option?(options)
        options.any? do |argument|
          argument == "--environment" ||
            argument.start_with?("--environment=") ||
            argument.start_with?("-e")
        end
      end
      private_class_method :environment_option?

      def reject_usage!(message)
        warn message
        raise SystemExit.new(2)
      end
      private_class_method :reject_usage!

      def load_plugin!
        require "minitest/testmon_plugin"
      rescue ConfigurationError => error
        warn error.message
        raise SystemExit.new(2)
      end
      private_class_method :load_plugin!

      def verify_project_root!(expected)
        return if Minitest::Testmon.configuration.project_root == expected

        Minitest::Testmon.take_early_observations
        reject_usage!(PROJECT_ROOT_MESSAGE)
      end
      private_class_method :verify_project_root!

      def select_project_configuration(cwd)
        return if ENV.key?("MINITEST_TESTMON_CONFIG")

        candidate = File.expand_path(".minitest-testmon.rb", cwd)
        ENV["MINITEST_TESTMON_CONFIG"] = candidate if File.file?(candidate)
      end
      private_class_method :select_project_configuration
    end
  end
end
