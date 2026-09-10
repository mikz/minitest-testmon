# frozen_string_literal: true

require "digest/sha2"

require_relative "testmon/version"
require_relative "testmon/environment"
require_relative "testmon/errors"
require_relative "testmon/canonical_json"
require_relative "testmon/engine"
require_relative "testmon/trace_owner"
require_relative "testmon/object_identity"
require_relative "testmon/provider_definition"
require_relative "testmon/configuration"
require_relative "testmon/path_resolver"
require_relative "testmon/ruby_path_policy"
require_relative "testmon/fingerprint"
require_relative "testmon/input"
require_relative "testmon/test_snapshot"
require_relative "testmon/selection"
require_relative "testmon/selector"
require_relative "testmon/snapshot_builder"
require_relative "testmon/run_evidence"
require_relative "testmon/artifact"
require_relative "testmon/observation"
require_relative "testmon/discovery_report"
require_relative "testmon/ruby_trace_capability"
require_relative "testmon/execution_context"
require_relative "testmon/thread_context_propagation"
require_relative "testmon/concurrent_context_propagation"
require_relative "testmon/action_cable_context_propagation"
require_relative "testmon/trace_point_factory"
require_relative "testmon/direct_file_reads"
require_relative "testmon/core_observer"
require_relative "testmon/coverage_collector"
require_relative "testmon/provider_observers"
require_relative "testmon/configured_provider"
require_relative "testmon/provider_registry"
require_relative "testmon/core_provider"
require_relative "testmon/bundles/rails_8_1"
require_relative "testmon/worker_spool"
require_relative "testmon/test_boundary_observer"
require_relative "testmon/store"
require_relative "testmon/runtime"
require_relative "testmon/cli"

module Minitest
  module Testmon
    class EarlyBuffer
      attr_reader :observations, :diagnostics

      def initialize
        @observations = []
        @diagnostics = []
      end

      def record(observation)
        @observations << observation
      end

      def incomplete(reason)
        @diagnostics << reason.to_s
      end
    end

    class << self
      def configuration
        @configuration ||= new_configuration
        auto_load_configuration!
        install_ruby_provider!(@configuration)
        @configuration
      end

      def configure
        config = @configuration ||= new_configuration
        yield config
        install_ruby_provider!(config, refresh: true)
        config
      end

      def reset!
        @early_observer&.close
        @early_observer = nil
        @early_buffer = nil
        @configuration = new_configuration
        @registry = nil
        @loaded_configuration_path = nil
        @loading_configuration = false
        @activating_rails = false
      end

      def registry
        install_ruby_provider!(configuration, refresh: !configuration.snapshot?)
        @registry ||= ProviderRegistry.new
      end

      def activate_rails_8_1!
        activate_rails_8_1_bundle!(configuration)
      end

      def load_configuration!(path)
        previous_loading = @loading_configuration
        source_path = File.expand_path(path)
        expanded = File.realpath(source_path)
        config = @configuration ||= new_configuration
        return config if @loaded_configuration_path == expanded
        config.record_config_source(expanded)
        @loading_configuration = true
        Kernel.load expanded
        @loaded_configuration_path = expanded
        config
      rescue ConfigurationError
        raise
      rescue StandardError, ScriptError => error
        detail = error.message.to_s.gsub(/\s+/, " ").strip
        detail = "(no message)" if detail.empty?
        raise ConfigurationError,
          "invalid Testmon configuration #{source_path.inspect}: #{error.class}: #{detail}",
          cause: error
      ensure
        @loading_configuration = previous_loading
      end

      def auto_load_configuration!
        previous_loading = @loading_configuration
        return if previous_loading
        path = ENV["MINITEST_TESTMON_CONFIG"]
        return unless path && File.file?(path)
        return if @loaded_configuration_path == File.realpath(path)

        @loading_configuration = true
        load_configuration!(path)
      ensure
        @loading_configuration = previous_loading
      end

      def activate_rails_8_1_bundle!(configuration)
        previous_activation = @activating_rails
        return false if previous_activation
        return false if @loading_configuration
        return false if configuration.snapshot?
        return false unless Bundles::Rails81.compatible?
        return false if configuration.bundle_disabled?(:rails_8_1)
        return false if Bundles::Rails81::PROVIDERS.all? do |name|
          configuration.providers.any? { |provider| provider.name == name }
        end

        @activating_rails = true
        @registry ||= ProviderRegistry.new
        activated = Bundles::Rails81.activate!(configuration, @registry)
        install_ruby_provider!(configuration, refresh: true) if activated
        activated
      ensure
        @activating_rails = previous_activation
      end

      def install_ruby_provider!(configuration, refresh: false)
        exists = configuration.providers.any? { |provider| provider.name == :ruby }
        return if exists && !refresh
        if exists
          configuration.replace_provider(:ruby, CoreProvider.new(configuration), version: 1)
        else
          configuration.provider(:ruby, CoreProvider.new(configuration), version: 1)
        end
        restart_early_observation!(configuration) if refresh && @early_observer
      end

      def restart_early_observation!(configuration)
        @early_observer.close
        @early_observer = build_early_observer(configuration)
      end

      def start_early_observation!
        return if @early_observer
        @early_buffer = EarlyBuffer.new
        config = configuration
        @early_observer = build_early_observer(config)
      rescue RuntimeError, PathError
        @early_buffer&.record(Observation.build(kind: :provider_error, operation: :early_start, reason: :late_activation))
      end

      def take_early_observations
        @early_observer&.close
        @early_observer = nil
        observations = @early_buffer&.observations || []
        @early_buffer = nil
        observations
      end

      private

      def new_configuration
        root = ENV["MINITEST_TESTMON_PROJECT_ROOT"] || Dir.pwd
        Configuration.new(cwd: root)
      end

      def build_early_observer(configuration)
        resolver = PathResolver.new(configuration.roots)
        handles = [CoreObserver.new(
          @early_buffer,
          resolver: resolver,
          ruby_path_policy: RubyPathPolicy.new(configuration)
        ).start]
        configuration.providers.each do |definition|
          next if definition.name == :ruby

          handles << ConfiguredProvider.new(definition).observe(@early_buffer, resolver: resolver)
        rescue ObserverUnavailable
          next
        end
        CompositeObserverHandle.new(handles)
      rescue
        handles&.reverse_each do |handle|
          handle.close
        rescue
          nil
        end
        raise
      end
    end
  end
end

Minitest::Testmon.start_early_observation! if Minitest::Testmon::Environment.enabled?
