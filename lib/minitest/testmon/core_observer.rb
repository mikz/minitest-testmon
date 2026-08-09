# frozen_string_literal: true

module Minitest
  module Testmon
    class CoreObserver
      DIRECT_READS = %i[read binread readlines foreach].freeze
      INSTANCE_READS = %i[read readpartial sysread each_line gets readline readlines].freeze
      CONSTANT_REFERENCE = /\b[A-Z][A-Z0-9_]*(?:::[A-Z][A-Z0-9_]*)*\b/
      MODULE_METHOD_ENUMERATORS = %i[
        public_instance_methods
        protected_instance_methods
        private_instance_methods
      ].map { |name| Module.instance_method(name) }.freeze
      MODULE_METHOD_LOOKUP = Module.instance_method(:instance_method)

      def initialize(
        session,
        resolver:,
        allowed_roots: [:project],
        ruby_paths: nil,
        unhookable_ruby_paths: [],
        test_only: false,
        observe_files: true,
        boundary_tracker: nil
      )
        @session = session
        @resolver = resolver
        @allowed_roots = Array(allowed_roots).map(&:to_sym).freeze
        @ruby_locator_cache = {}
        @ruby_path_allowance = {}
        @ruby_paths = index_ruby_paths(ruby_paths) if ruby_paths
        @unhookable_ruby_paths = Array(unhookable_ruby_paths).to_h do |path|
          [File.expand_path(path), true]
        end.freeze
        @test_only = test_only
        @observe_files = observe_files
        @boundary_tracker = boundary_tracker
        @closed = false
        @tracked_files = ObjectSpace::WeakMap.new
        @pending_loads = {}
        @unattributed_execution = {}
        @ruby_execution = {}
        @native_project_methods = {}
        @source_lines = {}
      end

      def start
        unless defined?(RubyVM::InstructionSequence) && RubyVM::InstructionSequence.respond_to?(:of)
          raise ObserverUnavailable, "targeted Ruby instruction-sequence tracing is unavailable"
        end

        events = %i[script_compiled]
        events.concat(%i[c_call c_return]) if @observe_files
        @trace = TracePoint.new(*events) { |event| observe(event) }
        @trace.enable
        install_existing_project_targets
        if !@observe_files && !@native_project_methods.empty?
          @native_trace = TracePoint.new(:c_call) { |event| observe(event) }
          @native_trace.enable
        end
        self
      rescue
        close
        raise
      end

      def close
        return if @closed
        @closed = true
        @trace&.disable
        @native_trace&.disable
        @target_traces&.each_value(&:disable)
      end

      private

      def observe(event)
        if event.event == :script_compiled
          observe_script(event)
          return
        end
        if @test_only && ExecutionContext.current_test.nil?
          observe_unattributed_execution(event)
          return
        end
        case event.event
        when :call, :b_call
          observe_ruby_execution(event)
        when :line
          observe_ruby_execution(event)
          observe_constant_reads(event)
        when :c_call
          observe_c_call(event)
        when :c_return
          observe_c_return(event)
        end
      rescue => error
        safe_record(Observation.build(
          kind: :provider_error,
          operation: event.event,
          test_id: ExecutionContext.current_test,
          reason: :provider_incomplete,
          details: {error: error.class.name}
        ))
      end

      def observe_unattributed_execution(event)
        return unless @boundary_tracker&.boundary_active?
        return unless RUBY_TARGET_TRACE_EVENTS.include?(event.event)
        locator = ruby_locator(event.path)
        return unless locator

        key = [Thread.current.object_id, locator.absolute_path]
        return if @unattributed_execution[key]
        @unattributed_execution[key] = true
        @session.incomplete(:ambiguous_context)
        safe_record(Observation.build(
          kind: :coverage_lines,
          provider: :"ruby@1",
          path: locator.absolute_path,
          operation: :unattributed_thread,
          scope: :suite,
          reason: :ambiguous_context,
          exists_at_observation: true,
          details: {thread: Thread.current.object_id, line: event.lineno}
        ))
      end

      def observe_script(event)
        iseq = event.instruction_sequence
        path = iseq.absolute_path || iseq.path
        locator = ruby_locator(path)
        return unless locator
        install_target(iseq)
        pending_load = @pending_loads.delete(Thread.current)
        operation = pending_load ? :load : :script_compiled
        safe_record(build_observation(:ruby_script, locator.absolute_path, operation, event))
      end

      def observe_ruby_execution(event)
        if event.event == :call && event.method_id == :require
          event_binding = event.binding
          return unless event_binding
          parameter = event.parameters.find { |kind, _name| %i[req opt].include?(kind) }
          return unless parameter&.last
          requested = event_binding.local_variable_get(parameter.last)
          path = resolve_feature(requested)
          locator = ruby_locator(path)
          return unless locator
          safe_record(build_observation(:ruby_require, locator.absolute_path, :require, event))
          return
        end

        test_id = ExecutionContext.current_test
        return unless test_id
        locator = ruby_locator(event.path)
        return unless locator
        record_ruby_execution(
          locator.absolute_path,
          event,
          line: event.lineno,
          operation: :"tracepoint_#{event.event}"
        )
      rescue NameError, TypeError
        nil
      end

      def record_ruby_execution(path, event, line:, operation:)
        test_id = ExecutionContext.current_test
        return unless test_id
        key = [test_id, path]
        return if @ruby_execution[key]
        @ruby_execution[key] = true
        safe_record(Observation.build(
          kind: :coverage_lines,
          path: path,
          operation: operation,
          test_id: test_id,
          exists_at_observation: true,
          details: {
            lines: [Integer(line)],
            event: event.event.to_s,
            method_id: event.method_id&.to_s
          }.compact
        ))
      end

      def observe_constant_reads(event)
        test_id = ExecutionContext.current_test
        return unless test_id
        callsite_locator = ruby_locator(event.path)
        return unless callsite_locator
        line = source_lines(callsite_locator.absolute_path)[event.lineno.to_i - 1]
        return unless line

        line.scan(CONSTANT_REFERENCE).uniq.each do |constant_name|
          location = constant_source_location(constant_name)
          next unless location
          source_locator = ruby_locator(location[0])
          next unless source_locator
          next if source_locator.absolute_path == callsite_locator.absolute_path
          safe_record(Observation.build(
            kind: :coverage_lines,
            provider: :"ruby@1",
            path: source_locator.absolute_path,
            operation: :constant_read,
            test_id: test_id,
            exists_at_observation: true,
            details: {lines: [Integer(location[1])], constant: constant_name}
          ))
        end
      rescue NameError, TypeError, ArgumentError, SystemCallError
        nil
      end

      def source_lines(path)
        @source_lines[path] ||= File.binread(path).lines
      end

      def constant_source_location(name)
        owner = Object
        parts = name.split("::")
        parts.each_with_index do |part, index|
          break unless owner.is_a?(Module) && owner.const_defined?(part, false)
          location = owner.const_source_location(part, false)
          return location if index == parts.length - 1
          owner = owner.const_get(part, false)
        end
        nil
      end

      def observe_c_call(event)
        receiver = event.self
        if event.method_id == :load && TraceOwner.label(event.defined_class).to_s.include?("Kernel")
          @pending_loads[Thread.current] = true
          return
        end

        native_source = @native_project_methods[[event.defined_class.object_id, event.method_id]]
        if native_source
          record_ruby_execution(
            native_source.fetch(:path),
            event,
            line: native_source.fetch(:line),
            operation: :native_method_call
          )
          return
        end

        if File === receiver && INSTANCE_READS.include?(event.method_id)
          return unless @tracked_files.key?(receiver)
          path = receiver.path
          locator = project_locator(path)
          safe_record(build_observation(:file_read, locator.absolute_path, event.method_id, event)) if locator
          return
        end

        return unless receiver.equal?(File) || receiver.equal?(IO)
        return unless DIRECT_READS.include?(event.method_id)
        return unless project_callsite?(event.path)
        safe_record(Observation.build(
          kind: :file_read,
          operation: event.method_id,
          test_id: ExecutionContext.current_test,
          callsite: callsite(event),
          reason: :opaque_c_call,
          details: {receiver: receiver.name}
        ))
      end

      def observe_c_return(event)
        if event.method_id == :load && TraceOwner.label(event.defined_class).to_s.include?("Kernel")
          @pending_loads.delete(Thread.current)
          return
        end
        return unless event.method_id == :initialize && File === event.self
        return unless project_callsite?(event.path)
        path = event.self.path
        locator = project_locator(path)
        return unless locator
        @tracked_files[event.self] = true
        safe_record(Observation.build(
          kind: :file_open,
          path: locator.absolute_path,
          operation: :"File.open",
          test_id: ExecutionContext.current_test,
          callsite: callsite(event),
          exists_at_observation: File.exist?(locator.absolute_path),
          reason: :conservative_file_construction
        ))
      rescue IOError
        nil
      end

      def build_observation(kind, path, operation, event)
        Observation.build(
          kind: kind,
          path: path,
          operation: operation,
          test_id: ExecutionContext.current_test,
          callsite: callsite(event),
          exists_at_observation: File.exist?(path)
        )
      end

      def safe_record(observation)
        @session.record(observation) unless @closed
      rescue PhaseError
        nil
      end

      def project_locator(path)
        return unless path.respond_to?(:to_path) || path.respond_to?(:to_str)
        path = path.to_path if path.respond_to?(:to_path)
        path = path.to_str if path.respond_to?(:to_str)
        return if path.start_with?("(") || !File.exist?(path)
        locator = @resolver.resolve(path)
        return unless @allowed_roots.include?(locator.root)
        return if nested_testmon_path?(locator.absolute_path)
        locator
      rescue PathError, ArgumentError, TypeError
        nil
      end

      def project_callsite?(path)
        !ruby_locator(path).nil?
      end

      def nested_testmon_path?(path)
        project_root = @resolver.root(:project)
        project_root != Testmon::GEM_ROOT &&
          Testmon::GEM_ROOT.start_with?("#{project_root}#{File::SEPARATOR}") &&
          (path == Testmon::GEM_ROOT || path.start_with?("#{Testmon::GEM_ROOT}#{File::SEPARATOR}"))
      rescue KeyError
        false
      end

      def ruby_locator(path)
        return project_locator(path) unless @ruby_paths
        return unless path.respond_to?(:to_path) || path.respond_to?(:to_str)
        path = path.to_path if path.respond_to?(:to_path)
        path = path.to_str if path.respond_to?(:to_str)
        return if path.start_with?("(")
        expanded = File.expand_path(path)
        return @ruby_locator_cache[expanded] if @ruby_locator_cache.key?(expanded)
        return if @ruby_path_allowance[expanded] == false

        locator = project_locator(expanded)
        allowed = locator && @ruby_paths.key?(locator.absolute_path)
        @ruby_path_allowance[expanded] = !!allowed
        @ruby_locator_cache[expanded] = locator if allowed
        locator if allowed
      rescue ArgumentError, TypeError
        nil
      end

      def index_ruby_paths(paths)
        Array(paths).each_with_object({}) do |path, index|
          expanded = File.expand_path(path)
          locator = project_locator(expanded)
          next unless locator
          index[expanded] = true
          index[locator.absolute_path] = true
          @ruby_locator_cache[expanded] = locator
          @ruby_locator_cache[locator.absolute_path] = locator
        end.freeze
      end

      def install_existing_project_targets
        @target_traces = {}
        return unless @ruby_paths

        ObjectSpace.each_object(Module) do |owner|
          method_names = MODULE_METHOD_ENUMERATORS.reduce([]) do |names, enumerator|
            names | enumerator.bind_call(owner, false)
          end
          method_names.each do |method_name|
            method = MODULE_METHOD_LOOKUP.bind_call(owner, method_name)
            location = method.source_location
            locator = ruby_locator(location&.first)
            next unless locator
            iseq = RubyVM::InstructionSequence.of(method)
            if iseq
              install_target(iseq)
            else
              @native_project_methods[[owner.object_id, method_name]] = {
                path: locator.absolute_path,
                line: Integer(location[1])
              }.freeze
            end
          rescue NameError, TypeError
            next
          end
        end
        ObjectSpace.each_object(Proc) do |block|
          next unless ruby_path_allowed?(block.source_location&.first)
          install_target(RubyVM::InstructionSequence.of(block))
        rescue TypeError
          next
        end
      end

      def install_target(iseq)
        return unless iseq
        return if iseq.respond_to?(:trace_points) && iseq.trace_points.empty?
        return if @unhookable_ruby_paths.key?(target_source_path(iseq))
        @target_traces ||= {}
        return if @target_traces.key?(iseq.object_id)

        trace = TracePoint.new(*RUBY_TARGET_TRACE_EVENTS) { |event| observe(event) }
        trace.enable(target: iseq)
        @target_traces[iseq.object_id] = trace
      rescue ArgumentError, RuntimeError => error
        trace&.disable
        @session.startup_incomplete(:trace_capability_changed) if @session.respond_to?(:startup_incomplete)
        @session.incomplete(:trace_capability_changed) unless @session.respond_to?(:startup_incomplete)
        safe_record(Observation.build(
          kind: :provider_error,
          provider: :"ruby@1",
          path: target_source_path(iseq),
          operation: :target_trace,
          reason: :provider_incomplete,
          details: {
            error: error.class.name,
            label: iseq.label.to_s,
            trace_points: iseq.trace_points.map { |line, event| [line, event.to_s] }
          }
        ))
        nil
      end

      def target_source_path(iseq)
        path = iseq.absolute_path || iseq.path
        ruby_locator(path)&.absolute_path
      rescue ArgumentError, TypeError
        nil
      end

      def ruby_path_allowed?(path)
        path && !ruby_locator(path).nil?
      end

      def callsite(event)
        locator = project_locator(event.path)
        path = locator ? locator.key : event.path
        {path: path, line: event.lineno, owner: TraceOwner.label(event.defined_class)}
      end

      def resolve_feature(feature)
        value = feature.to_path if feature.respond_to?(:to_path)
        value ||= feature.to_s
        candidates = [value, "#{value}.rb"]
        return candidates.find { |candidate| File.file?(candidate) } if Pathname(value).absolute?
        $LOAD_PATH.each do |load_path|
          candidate = candidates.find { |entry| File.file?(File.join(load_path, entry)) }
          return File.join(load_path, candidate) if candidate
        end
        candidates.find { |entry| File.file?(File.expand_path(entry)) }
      end
    end
  end
end
