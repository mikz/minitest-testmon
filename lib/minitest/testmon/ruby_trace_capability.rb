# frozen_string_literal: true

module Minitest
  module Testmon
    RUBY_TARGET_TRACE_EVENTS = %i[line call b_call].freeze

    RubyTraceCapability = Data.define(:identity, :type, :label, :trace_points) do
      def signature
        {
          identity: identity,
          type: type.to_s,
          label: label.to_s,
          trace_points: trace_points.map { |line, event| [line, event.to_s] }
        }
      end
    end

    RubyTraceCapabilityResult = Data.define(:unhookable_targets) do
      def target_traceable?
        unhookable_targets.empty?
      end
    end

    # Probes only the MRI capability Testmon relies on for attribution. Ruby
    # source change detection is intentionally handled by ContentFingerprint.
    class RubyTraceCapabilityProbe
      def initialize(resolver)
        @resolver = resolver
      end

      def call(path)
        locator = @resolver.resolve(path)
        source = File.binread(locator.absolute_path)
        root = RubyVM::InstructionSequence.compile(
          source,
          locator.key,
          locator.key,
          1,
          coverage_enabled: false
        )
        targets = []
        types = serialized_types(root.to_a)
        collect(root, [], targets, types)
        RubyTraceCapabilityResult.new(unhookable_targets: targets.sort_by(&:identity).freeze)
      rescue SyntaxError, RuntimeError, TypeError, SystemCallError, IOError, PathError => error
        RubyTraceCapabilityResult.new(
          unhookable_targets: [RubyTraceCapability.new(
            identity: "probe_failure",
            type: :unknown,
            label: error.class.name.freeze,
            trace_points: [].freeze
          )].freeze
        )
      end

      private

      # ISeq#to_a recursively serializes descendants. Serialize the tree once,
      # but retain MRI's each_child order for stable occurrence identities.
      def serialized_types(root)
        types = {}
        pending = [root]
        until pending.empty?
          value = pending.pop
          next unless value.is_a?(Array)
          if value.first == "YARVInstructionSequence/SimpleDataFormat"
            key = [value[5], value[8]]
            type = value[9]
            types[key] = (types.key?(key) && types[key] != type) ? nil : type
          end
          value.each { |child| pending << child if child.is_a?(Array) }
        end
        types
      end

      def instruction_type(iseq, types)
        # Labels and lines normally identify a type uniquely. Fall back for
        # ambiguous metadata rather than infer a type from a label convention.
        types[[iseq.label, iseq.first_lineno]] || iseq.to_a[9]
      end

      def collect(iseq, parent_identity, output, types)
        type = instruction_type(iseq, types)
        component = [type.to_s, iseq.label.to_s]
        identity = parent_identity + [component]
        trace_points = iseq.trace_points.map { |line, event| [Integer(line), event.to_sym].freeze }.freeze
        if trace_points.any? && !target_traceable?(iseq)
          output << RubyTraceCapability.new(
            identity: identity.map { |item_type, label| "#{item_type}:#{label}" }.join("/"),
            type: type,
            label: iseq.label.to_s.freeze,
            trace_points: trace_points
          )
        end

        counts = Hash.new(0)
        iseq.each_child do |child|
          child_type = instruction_type(child, types)
          key = [child_type, child.label]
          occurrence = counts[key]
          counts[key] += 1
          collect(child, identity + [["occurrence", occurrence.to_s]], output, types)
        end
      end

      def target_traceable?(iseq)
        trace = TracePoint.new(*RUBY_TARGET_TRACE_EVENTS) {}
        trace.enable(target: iseq)
        enabled = true
        true
      rescue ArgumentError, RuntimeError
        false
      ensure
        # MRI 4.0 can corrupt subsequent targeted tracing if disable is called
        # after enable rejected an unsupported ISeq.
        trace.disable if enabled
      end
    end
  end
end
