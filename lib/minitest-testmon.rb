# frozen_string_literal: true

testmon_request = ENV["MINITEST_TESTMON"] == "1" ||
  ARGV.any? { |argument| argument.start_with?("--testmon") }

if defined?(Rails::Railtie)
  if testmon_request
    require_relative "minitest/testmon/rails_bootstrap"

    module Minitest
      module Testmon
        class Railtie < Rails::Railtie
          config.before_configuration do
            next unless RailsBootstrap.requested?(ARGV)

            test_command = defined?(Rails::Command::TestCommand)
            rake_test_prepare = RailsBootstrap.rake_test_prepare?
            application_root = if test_command && rake_test_prepare
              Rails::Command.application_root
            end
            RailsBootstrap.call(
              ARGV,
              application_root: application_root,
              test_command: test_command,
              rake_test_prepare: rake_test_prepare
            )
          end
        end
      end
    end
  end
elsif testmon_request
  ENV["MINITEST_TESTMON"] = "1" if ARGV.include?("--testmon")
  require "minitest/testmon_plugin"
end
