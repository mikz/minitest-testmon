# frozen_string_literal: true

require "digest"
require "prism"

module Minitest
  module Testmon
    ISeqBody = Data.define(:identity, :type, :label, :digest, :lines)
    ISeqTraceCapability = Data.define(:identity, :type, :label, :trace_points) do
      def signature
        {
          identity: identity,
          type: type.to_s,
          label: label.to_s,
          trace_points: trace_points.map { |line, event| [line, event.to_s] }
        }
      end
    end
    ISeqResult = Data.define(:locator, :file_fingerprint, :bodies, :reason, :unhookable_targets) do
      def fallback?
        !reason.nil?
      end

      def target_traceable?
        unhookable_targets.empty?
      end
    end

    class CanonicalEncoder
      def digest(value)
        output = Digest::SHA256.new
        append(output, value)
        output.hexdigest
      end

      private

      def append(output, value)
        case value
        when NilClass then output << "n"
        when TrueClass then output << "t"
        when FalseClass then output << "f"
        when Integer then scalar(output, "i", value.to_s)
        when Float then scalar(output, "d", [value].pack("G"))
        when Symbol then scalar(output, "y", value.to_s)
        when String
          scalar(output, "s", value.encoding.name)
          scalar(output, "b", value.b)
        when Array
          scalar(output, "a", value.length.to_s)
          value.each { |item| append(output, item) }
        when Hash
          scalar(output, "h", value.length.to_s)
          value.each { |key, item|
            append(output, key)
            append(output, item)
          }
        when Regexp
          append(output, [:regexp, value.source, value.options, value.encoding.name])
        when Range
          append(output, [:range, value.begin, value.end, value.exclude_end?])
        when Rational
          append(output, [:rational, value.numerator, value.denominator])
        when Complex
          append(output, [:complex, value.real, value.imaginary])
        when Encoding
          append(output, [:encoding, value.name])
        when Module
          name = value.name
          raise UnsupportedISeq, "unsupported anonymous ISeq constant: #{value.class}" if name.to_s.empty?

          append(output, [:constant, value.class.name, name])
        else
          raise UnsupportedISeq, "unsupported ISeq operand: #{value.class}"
        end
      end

      def scalar(output, tag, bytes)
        output << tag << bytes.bytesize.to_s << ":" << bytes
      end
    end

    class ISeqFingerprint
      MAGIC = "YARVInstructionSequence/SimpleDataFormat"

      def initialize(resolver, encoder: CanonicalEncoder.new)
        @resolver = resolver
        @encoder = encoder
      end

      def call(path)
        locator = @resolver.resolve(path)
        file_fingerprint = ContentFingerprint.call(locator.absolute_path)
        unless file_fingerprint.known?
          return ISeqResult.new(
            locator: locator,
            file_fingerprint: file_fingerprint,
            bodies: [],
            reason: file_fingerprint.reason,
            unhookable_targets: []
          )
        end
        return fallback(locator, file_fingerprint, :unsupported_iseq) unless Engine.supported?

        source = File.binread(locator.absolute_path)
        logical_path = locator.key
        root = RubyVM::InstructionSequence.compile(source, logical_path, logical_path, 1, coverage_enabled: false)
        unhookable_targets = collect_unhookable_targets(root)
        if top_level_state_write?(source)
          return fallback(
            locator,
            file_fingerprint,
            :whole_file_fallback,
            unhookable_targets: unhookable_targets
          )
        end
        bodies = []
        walk(root, [], bodies)
        return fallback(locator, file_fingerprint, :unsupported_iseq) if bodies.empty?
        ISeqResult.new(
          locator: locator,
          file_fingerprint: file_fingerprint,
          bodies: bodies.freeze,
          reason: nil,
          unhookable_targets: unhookable_targets
        )
      rescue SyntaxError, UnsupportedISeq, RuntimeError, TypeError
        fallback(
          locator,
          file_fingerprint,
          :unsupported_iseq,
          unhookable_targets: unhookable_targets
        )
      rescue PathError
        ISeqResult.new(
          locator: nil,
          file_fingerprint: Fingerprint.unknown(:outside_root),
          bodies: [],
          reason: :outside_root,
          unhookable_targets: []
        )
      rescue SystemCallError, IOError
        fallback(
          locator,
          file_fingerprint,
          :source_race,
          unhookable_targets: unhookable_targets
        )
      end

      private

      def fallback(locator, file_fingerprint, reason, unhookable_targets: [])
        ISeqResult.new(
          locator: locator,
          file_fingerprint: file_fingerprint || Fingerprint.unknown(reason),
          bodies: [].freeze,
          reason: reason,
          unhookable_targets: Array(unhookable_targets).freeze
        )
      end

      def top_level_state_write?(source)
        result = Prism.parse(source)
        raise UnsupportedISeq, "Prism could not parse Ruby source" unless result.success?

        result.value.statements.body.any? do |node|
          node.is_a?(Prism::ConstantWriteNode) ||
            node.is_a?(Prism::ConstantPathWriteNode) ||
            node.is_a?(Prism::GlobalVariableWriteNode) ||
            node.is_a?(Prism::InstanceVariableWriteNode) ||
            node.is_a?(Prism::ClassVariableWriteNode)
        end
      end

      def walk(iseq, parent_identity, output)
        array = iseq.to_a
        raise UnsupportedISeq, "unknown ISeq format" unless iseq_array?(array)

        component = [array[9].to_s, iseq.label.to_s]
        identity = parent_identity + [component]
        output << ISeqBody.new(
          identity: identity.map { |type, label| "#{type}:#{label}" }.join("/"),
          type: array[9],
          label: iseq.label,
          digest: @encoder.digest(canonical_body(array)),
          lines: iseq.trace_points.filter_map { |line, event| line if event == :line }.uniq.sort.freeze
        )

        counts = Hash.new(0)
        iseq.each_child do |child|
          child_array = child.to_a
          key = [child_array[9], child.label]
          occurrence = counts[key]
          counts[key] += 1
          walk(child, identity + [["occurrence", occurrence.to_s]], output)
        end
      end

      def collect_unhookable_targets(root)
        output = []
        walk_trace_capabilities(root, [], output)
        output.sort_by(&:identity).freeze
      end

      def walk_trace_capabilities(iseq, parent_identity, output)
        array = iseq.to_a
        raise UnsupportedISeq, "unknown ISeq format" unless iseq_array?(array)

        component = [array[9].to_s, iseq.label.to_s]
        identity = parent_identity + [component]
        trace_points = iseq.trace_points.map { |line, event| [Integer(line), event.to_sym].freeze }.freeze
        if trace_points.any? && !target_traceable?(iseq)
          output << ISeqTraceCapability.new(
            identity: identity.map { |type, label| "#{type}:#{label}" }.join("/"),
            type: array[9],
            label: iseq.label.to_s.freeze,
            trace_points: trace_points
          )
        end

        counts = Hash.new(0)
        iseq.each_child do |child|
          child_array = child.to_a
          key = [child_array[9], child.label]
          occurrence = counts[key]
          counts[key] += 1
          walk_trace_capabilities(child, identity + [["occurrence", occurrence.to_s]], output)
        end
      end

      def target_traceable?(iseq)
        trace = TracePoint.new(:line, :call) {}
        trace.enable(target: iseq)
        true
      rescue ArgumentError, RuntimeError
        false
      ensure
        trace&.disable
      end

      def canonical_body(array)
        labels = {}
        child_counter = [0]
        bytecode = array[13].reject do |item|
          item.is_a?(Integer) || (item.is_a?(Symbol) && item.to_s.start_with?("RUBY_EVENT_"))
        end
        {
          type: array[9],
          locals: canonical_value(array[10], labels, child_counter),
          params: canonical_value(array[11], labels, child_counter),
          catch_table: canonical_value(array[12], labels, child_counter),
          bytecode: canonical_value(bytecode, labels, child_counter)
        }
      end

      def canonical_value(value, labels, child_counter)
        if iseq_array?(value)
          ordinal = child_counter[0]
          child_counter[0] += 1
          return [:child, value[9], value[5], ordinal]
        end

        case value
        when Array
          value.map { |item| canonical_value(item, labels, child_counter) }
        when Hash
          value.to_h { |key, item| [canonical_value(key, labels, child_counter), canonical_value(item, labels, child_counter)] }
        when Symbol
          if value.match?(/\Alabel_\d+\z/)
            labels[value] ||= :"L#{labels.length}"
          else
            value
          end
        else
          value
        end
      end

      def iseq_array?(value)
        value.is_a?(Array) && value.length == 14 && value[0] == MAGIC
      end
    end
  end
end
