# frozen_string_literal: true

require_relative "global_trace_router"

module Minitest
  module Testmon
    module CanonicalObservationValue
      module_function

      def call(value)
        case value
        when NilClass, TrueClass, FalseClass, String, Integer
          value.is_a?(String) ? value.dup.freeze : value
        when Float
          raise TypeError, "non-finite numbers are not canonical" unless value.finite?
          value
        when Array
          value.map { |item| call(item) }.freeze
        when Hash
          value.to_h do |key, item|
            raise TypeError, "observation hash keys must be strings" unless key.is_a?(String)
            [key.dup.freeze, call(item)]
          end.freeze
        else
          raise TypeError, "unsupported observation value: #{value.class}"
        end
      end

      def payload(value)
        return {}.freeze unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, item), output|
          canonical_key = key.is_a?(String) ? key.dup.freeze : key
          next unless canonical_key.is_a?(String) || canonical_key.is_a?(Symbol)
          output[canonical_key] = payload_value(item)
        rescue TypeError
          next
        end.freeze
      end

      def payload_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), output|
            canonical_key = key.is_a?(String) ? key.dup.freeze : key
            raise TypeError unless canonical_key.is_a?(String) || canonical_key.is_a?(Symbol)
            output[canonical_key] = payload_value(item)
          end.freeze
        when Array
          value.map { |item| payload_value(item) }.freeze
        when Symbol
          value
        else
          call(value)
        end
      end
    end

    class TraceObservation
      def initialize(trace)
        @trace = trace
        @event = trace.event
        @method_id = trace.method_id
        @path = resource_path(trace) || compiled_path(trace) || trace.path
        @lineno = trace.lineno
        freeze
      end

      attr_reader :event, :method_id, :path, :lineno

      def local(name)
        binding = @trace.binding
        return unless binding
        key = name.to_sym
        return unless binding.local_variable_defined?(key)
        binding.local_variable_get(key)
      rescue ArgumentError, NameError, RuntimeError
        nil
      end

      private

      def resource_path(trace)
        receiver = trace.self
        file_receiver = File === receiver
        io_receiver = defined?(IO) && IO === receiver
        return unless file_receiver || io_receiver
        receiver.path
      rescue IOError, NoMethodError
        nil
      end

      def compiled_path(trace)
        return unless trace.event == :script_compiled
        sequence = trace.instruction_sequence
        sequence&.absolute_path || sequence&.path
      rescue RuntimeError
        nil
      end
    end

    class NotificationObservation
      attr_reader :name, :payload

      def initialize(name, payload)
        @name = name.to_s.dup.freeze
        @payload = CanonicalObservationValue.payload(payload)
        freeze
      end
    end

    class TestStartObservation
      attr_reader :class_name, :name

      def initialize(test)
        @test_class = test.class
        @class_name = @test_class.name.to_s.dup.freeze
        @name = test.name.to_s.dup.freeze
        freeze
      end

      def class_value(method_name)
        name = method_name.to_sym
        return unless @test_class.respond_to?(name)

        canonical_class_value(@test_class.public_send(name))
      end

      def test_id
        "#{class_name}##{name}"
      end

      private

      # Internal provider primitive used by the core test-definition input.
      # Keeping it private preserves the deliberately small provider wrapper
      # API exposed to third-party built-in observers.
      def __source_location
        @test_class.instance_method(@name).source_location
      rescue NameError
        nil
      end

      def canonical_class_value(value)
        case value
        when Pathname
          value.to_s.dup.freeze
        when Symbol
          value.to_s.freeze
        when Array
          value.map { |item| canonical_class_value(item) }.freeze
        when Hash
          value.to_h do |key, item|
            [canonical_class_value(key).to_s.freeze, canonical_class_value(item)]
          end.freeze
        else
          CanonicalObservationValue.call(value)
        end
      end
    end

    class CompositeObserverHandle
      def initialize(handles)
        @handles = handles.freeze
        @closed = false
      end

      def close
        return if @closed
        @closed = true
        errors = []
        @handles.reverse_each do |handle|
          handle.close
        rescue => error
          errors << error
        end
        raise errors.first if errors.any?
        true
      end
    end

    class TracePointObserverHandle
      def initialize(definition, observer, session, resolver)
        @definition = definition
        @observer = observer
        @session = session
        @resolver = resolver
        @closed = false
        @owner, @method_name = resolve_target!(observer.target)
      end

      def start
        if @session.respond_to?(:global_trace_router)
          @trace = @session.global_trace_router.subscribe(@observer.event, @method_name) { |trace| observe(trace) }
        else
          filters = @method_name ? {@observer.event => {@method_name => true}} : {}
          @trace = TracePointFactory.build([@observer.event], filters) { |trace| observe(trace) }
          @trace.enable
        end
        self
      rescue ArgumentError => error
        raise ObserverUnavailable, error.message
      end

      def close
        return if @closed
        @closed = true
        @trace&.disable
      end

      private

      def resolve_target!(target)
        return [:any, nil] if target == :any
        if target.is_a?(String)
          owner_name, separator, method_name = target.rpartition(".")
          raise ObserverUnavailable, "TracePoint target is unavailable: #{target}" if separator.empty?
          owner = owner_name.split("::").inject(Object) { |namespace, name| namespace.const_get(name, false) }
          method_name = method_name.to_sym
          unless owner.respond_to?(method_name, true)
            raise ObserverUnavailable, "TracePoint target is unavailable: #{target}"
          end
          return [owner, method_name]
        end
        unless target.is_a?(Array) && target.length == 2
          raise ObserverUnavailable, "TracePoint target must be :any or [owner, method_name]"
        end
        owner, method_name = target
        method_name = method_name.to_sym
        available = if owner.is_a?(Module)
          owner.respond_to?(method_name, true) ||
            owner.method_defined?(method_name) ||
            owner.private_method_defined?(method_name) ||
            owner.protected_method_defined?(method_name)
        else
          owner.respond_to?(method_name, true)
        end
        raise ObserverUnavailable, "TracePoint target is unavailable: #{owner}.#{method_name}" unless available
        [owner, method_name]
      rescue NameError
        raise ObserverUnavailable, "TracePoint target is unavailable"
      end

      def observe(trace)
        return if @closed || !matching?(trace)
        wrapper = TraceObservation.new(trace)
        if opaque_file_call?(trace)
          return unless callsite_in_root?(trace.path)
          return record_failure(
            :opaque_c_call,
            RuntimeError.new("native file arguments are unavailable"),
            operation: trace.event,
            trace: trace,
            details: {"candidate_path" => literal_candidate_path(trace)}
          )
        end
        reason = :conservative_file_construction if trace.event == :c_return && trace.method_id == :initialize && File === trace.self
        operation = if trace.event == :script_compiled && %i[load require].include?(trace.method_id)
          trace.method_id
        else
          trace.event
        end
        record(
          wrapper,
          operation: operation,
          callsite: {path: trace.path, line: trace.lineno, owner: TraceOwner.label(trace.defined_class)},
          reason: reason
        )
      rescue => error
        record_failure(:observer_error, error, operation: trace.event, trace: trace)
      end

      def matching?(trace)
        return true if @owner == :any
        return false unless trace.method_id == @method_name
        receiver = trace.self
        defined_class = trace.defined_class
        return true if ObjectIdentity.equal?(receiver, @owner) || ObjectIdentity.equal?(defined_class, @owner)
        return true if @owner.is_a?(Module) && ObjectIdentity.equal?(defined_class, @owner.singleton_class)
        return true if @owner.is_a?(Module) && @owner === receiver
        defined_class.is_a?(Module) && @owner.is_a?(Module) && !!(defined_class <= @owner)
      rescue TypeError
        false
      end

      def opaque_file_call?(trace)
        return false unless trace.event == :c_call
        return false unless ObjectIdentity.equal?(trace.self, File) || ObjectIdentity.equal?(trace.self, IO)
        %i[read binread readlines foreach].include?(trace.method_id)
      end

      def callsite_in_root?(path)
        locator = @resolver.resolve(path)
        return false unless locator.root == :project
        return false if nested_testmon_path?(locator.absolute_path)

        true
      rescue PathError, ArgumentError, TypeError
        false
      end

      def nested_testmon_path?(path)
        project_root = @resolver.root(:project)
        project_root != Testmon::GEM_ROOT &&
          Testmon::GEM_ROOT.start_with?("#{project_root}#{File::SEPARATOR}") &&
          (path == Testmon::GEM_ROOT || path.start_with?("#{Testmon::GEM_ROOT}#{File::SEPARATOR}"))
      end

      def literal_candidate_path(trace)
        locator = @resolver.resolve(trace.path, allow_missing: false)
        return unless locator.root == :project
        line = File.binread(locator.absolute_path).lines[trace.lineno.to_i - 1]
        return unless line
        literals = line.scan(/["']([^"']+)["']/).flatten
        relative = literals.rfind { |value| value.include?(File::SEPARATOR) || value.include?(".") }
        return unless relative
        @resolver.resolve(File.expand_path(relative, @resolver.root(:project))).absolute_path
      rescue PathError, SystemCallError, ArgumentError
        nil
      end

      def record(wrapper, operation:, callsite:, reason: nil)
        path = extract_path(wrapper)
        return if reason == :conservative_file_construction && (!path || !File.file?(path))
        details = extract_details(wrapper)
        test_id = ExecutionContext.current_test
        @session.record(Observation.build(
          kind: @observer.event_kind,
          provider: @definition.id.to_sym,
          path: path,
          operation: operation,
          test_id: test_id,
          callsite: callsite,
          exists_at_observation: path && File.exist?(path),
          reason: reason,
          details: details || {}
        ))
      rescue PathError => error
        if @definition.name == :ruby
          @session.record(Observation.build(
            kind: @observer.event_kind,
            provider: @definition.id.to_sym,
            operation: operation,
            test_id: ExecutionContext.current_test,
            callsite: callsite,
            reason: reason,
            details: {}
          ))
        else
          record_failure(:outside_root, error, operation: operation, callsite: callsite)
        end
      rescue TypeError => error
        record_failure(:noncanonical_observation, error, operation: operation, callsite: callsite)
      rescue => error
        record_failure(:extractor_error, error, operation: operation, callsite: callsite)
      end

      def extract_path(wrapper)
        value = @observer.path ? @observer.path.call(wrapper) : wrapper.path
        return if value.nil?
        unless value.is_a?(String) || value.is_a?(Pathname)
          raise TypeError, "path extractor must return String, Pathname, or nil"
        end
        @resolver.resolve(value.to_s).absolute_path
      end

      def extract_details(wrapper)
        return {}.freeze unless @observer.details
        CanonicalObservationValue.call(@observer.details.call(wrapper))
      end

      def record_failure(reason, error, operation:, trace: nil, callsite: nil, details: nil)
        @session.incomplete(reason) unless reason == :opaque_c_call
        @session.record(Observation.build(
          kind: @observer.event_kind,
          provider: @definition.id.to_sym,
          operation: operation,
          test_id: ExecutionContext.current_test,
          callsite: callsite || (trace && {
            path: trace.path,
            line: trace.lineno,
            owner: TraceOwner.label(trace.defined_class)
          }),
          reason: reason,
          details: {"error" => error.class.name}.merge(details || {}).compact
        ))
      rescue PhaseError
        nil
      end
    end

    class NotificationObserverHandle
      def initialize(definition, observer, session, resolver)
        @definition = definition
        @observer = observer
        @session = session
        @resolver = resolver
        @closed = false
      end

      def start
        begin
          require "active_support/isolated_execution_state"
        rescue LoadError
          nil
        end
        unless defined?(ActiveSupport::Notifications) && ActiveSupport::Notifications.respond_to?(:subscribe)
          raise ObserverUnavailable, "ActiveSupport::Notifications is unavailable"
        end
        @subscriber = ActiveSupport::Notifications.subscribe(@observer.notification_name) do |*arguments|
          observe(arguments)
        end
        self
      rescue ObserverUnavailable
        raise
      rescue => error
        raise ObserverUnavailable, error.message
      end

      def close
        return if @closed
        @closed = true
        ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
      end

      private

      def observe(arguments)
        return if @closed
        name, payload = notification_values(arguments)
        wrapper = NotificationObservation.new(name, payload)
        record(wrapper)
      rescue => error
        record_failure(:observer_error, error)
      end

      def notification_values(arguments)
        if arguments.length == 1 && arguments[0].respond_to?(:name) && arguments[0].respond_to?(:payload)
          [arguments[0].name, arguments[0].payload]
        else
          [arguments[0], arguments[4] || {}]
        end
      end

      def record(wrapper)
        raw_path = @observer.path&.call(wrapper)
        unless raw_path.nil? || raw_path.is_a?(String) || raw_path.is_a?(Pathname)
          raise TypeError, "path extractor must return String, Pathname, or nil"
        end
        path = raw_path && @resolver.resolve(raw_path.to_s).absolute_path
        details = @observer.details ? CanonicalObservationValue.call(@observer.details.call(wrapper)) : {}.freeze
        test_id = ExecutionContext.current_test
        @session.record(Observation.build(
          kind: @observer.event_kind,
          provider: @definition.id.to_sym,
          path: path,
          operation: @observer.notification_name.to_sym,
          test_id: test_id,
          exists_at_observation: path && File.exist?(path),
          details: details || {}
        ))
      rescue PathError => error
        record_failure(:outside_root, error, path: raw_path)
      rescue TypeError => error
        record_failure(:noncanonical_observation, error)
      rescue => error
        record_failure(:extractor_error, error)
      end

      def record_failure(reason, error, path: nil)
        @session.incomplete(reason) unless reason == :outside_root
        path = path.to_s if path.respond_to?(:to_path) || path.respond_to?(:to_str)
        path = File.realpath(File.expand_path(path)) if path && reason == :outside_root
        @session.record(Observation.build(
          kind: @observer.event_kind,
          provider: @definition.id.to_sym,
          path: path,
          operation: @observer.notification_name.to_sym,
          test_id: ExecutionContext.current_test,
          exists_at_observation: path && File.exist?(path),
          reason: reason,
          details: {"error" => error.class.name}
        ))
      rescue SystemCallError, ArgumentError, TypeError
        @session.incomplete(reason)
        @session.record(Observation.build(
          kind: @observer.event_kind,
          provider: @definition.id.to_sym,
          operation: @observer.notification_name.to_sym,
          test_id: ExecutionContext.current_test,
          reason: reason,
          details: {"error" => error.class.name}
        ))
      rescue PhaseError
        nil
      end
    end
  end
end
