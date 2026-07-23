# frozen_string_literal: true

require_relative "test_helper"

class ISeqFingerprintTest < TestmonTestCase
  SOURCE = <<~RUBY
    class Example
      def call(value)
        [1].map do |number|
          number + value
        end
      end

      def untouched
        42
      end
    end
  RUBY

  def test_line_shift_is_ignored_and_nested_change_is_local
    with_project do |project|
      base_path = write_file(File.join(project, "base.rb"), SOURCE)
      shifted_path = write_file(File.join(project, "shifted.rb"), "# comment\n\n#{SOURCE}")
      changed_path = write_file(File.join(project, "changed.rb"), SOURCE.sub("number + value", "number * value"))
      resolver = Minitest::Testmon::PathResolver.new(project: project)
      fingerprinter = Minitest::Testmon::ISeqFingerprint.new(resolver)

      base = fingerprinter.call(base_path)
      shifted = fingerprinter.call(shifted_path)
      changed = fingerprinter.call(changed_path)

      refute base.fallback?
      assert_equal hashes(base), hashes(shifted)
      assert_equal body(base, "method:call").digest, body(changed, "method:call").digest
      refute_equal body(base, "block in call").digest, body(changed, "block in call").digest
      assert_equal body(base, "method:untouched").digest, body(changed, "method:untouched").digest
    end
  end

  def test_duplicate_bodies_have_separate_identities
    with_project do |project|
      path = write_file(File.join(project, "duplicates.rb"), <<~RUBY)
        class One
          def value = 42
        end
        class Two
          def value = 42
        end
      RUBY
      result = Minitest::Testmon::ISeqFingerprint.new(Minitest::Testmon::PathResolver.new(project: project)).call(path)
      methods = result.bodies.select { |item| item.type == :method }

      assert_equal 2, methods.length
      refute_equal methods[0].identity, methods[1].identity
      assert_equal methods[0].digest, methods[1].digest
    end
  end

  def test_call_target_and_keyword_call_changes_affect_only_the_method
    with_project do |project|
      baseline = fingerprint(project, <<~RUBY)
        class Example
          def call(value)
            target(value, mode: :fast)
          end

          def untouched = 42
        end
      RUBY
      target_changed = fingerprint(project, <<~RUBY)
        class Example
          def call(value)
            replacement(value, mode: :fast)
          end

          def untouched = 42
        end
      RUBY
      keyword_changed = fingerprint(project, <<~RUBY)
        class Example
          def call(value)
            target(value, strategy: :fast)
          end

          def untouched = 42
        end
      RUBY

      refute baseline.fallback?
      refute target_changed.fallback?
      refute keyword_changed.fallback?
      refute_equal method_digest(baseline, "call"), method_digest(target_changed, "call")
      refute_equal method_digest(baseline, "call"), method_digest(keyword_changed, "call")
      assert_equal method_digest(baseline, "untouched"), method_digest(target_changed, "untouched")
      assert_equal method_digest(baseline, "untouched"), method_digest(keyword_changed, "untouched")
    end
  end

  def test_keyword_parameters_and_defaults_are_fingerprinted
    with_project do |project|
      baseline = fingerprint(project, <<~RUBY)
        def call(value = fallback, scale:, mode: :fast, **options)
          target(value, scale: scale, mode: mode, **options)
        end
      RUBY
      positional_default_changed = fingerprint(project, <<~RUBY)
        def call(value = replacement, scale:, mode: :fast, **options)
          target(value, scale: scale, mode: mode, **options)
        end
      RUBY
      keyword_default_changed = fingerprint(project, <<~RUBY)
        def call(value = fallback, scale:, mode: :safe, **options)
          target(value, scale: scale, mode: mode, **options)
        end
      RUBY
      required_keyword_changed = fingerprint(project, <<~RUBY)
        def call(value = fallback, factor:, mode: :fast, **options)
          target(value, scale: factor, mode: mode, **options)
        end
      RUBY

      [baseline, positional_default_changed, keyword_default_changed, required_keyword_changed].each do |result|
        refute result.fallback?
      end
      refute_equal method_digest(baseline, "call"), method_digest(positional_default_changed, "call")
      refute_equal method_digest(baseline, "call"), method_digest(keyword_default_changed, "call")
      refute_equal method_digest(baseline, "call"), method_digest(required_keyword_changed, "call")
    end
  end

  def test_rescue_and_ensure_bodies_are_supported_and_change_independently
    with_project do |project|
      baseline = fingerprint(project, rescue_source(rescue_call: "recover", ensure_call: "cleanup"))
      rescue_changed = fingerprint(project, rescue_source(rescue_call: "retry_value", ensure_call: "cleanup"))
      ensure_changed = fingerprint(project, rescue_source(rescue_call: "recover", ensure_call: "release"))

      [baseline, rescue_changed, ensure_changed].each { |result| refute result.fallback? }
      refute_equal body_digest(baseline, :rescue), body_digest(rescue_changed, :rescue)
      assert_equal body_digest(baseline, :ensure), body_digest(rescue_changed, :ensure)
      assert_equal body_digest(baseline, :rescue), body_digest(ensure_changed, :rescue)
      refute_equal body_digest(baseline, :ensure), body_digest(ensure_changed, :ensure)
    end
  end

  def test_nonempty_trace_points_can_still_reject_targeted_line_and_call_hooks
    with_project do |project|
      path = write_file(File.join(project, "unhookable.rb"), <<~RUBY)
        module ExactUnhookableTarget
        end
      RUBY
      root = RubyVM::InstructionSequence.compile_file(path, coverage_enabled: false)
      target = nil
      root.each_child do |child|
        target = child if child.label == "<module:ExactUnhookableTarget>"
      end

      refute_nil target
      assert_equal [[1, :class], [2, :end]], target.trace_points
      trace = TracePoint.new(:line, :call) {}
      error = assert_raises(ArgumentError) { trace.enable(target: target) }
      assert_equal "can not enable any hooks", error.message

      result = Minitest::Testmon::ISeqFingerprint.new(
        Minitest::Testmon::PathResolver.new(project: project)
      ).call(path)
      capability = result.unhookable_targets.find do |item|
        item.label == "<module:ExactUnhookableTarget>"
      end

      refute_nil capability
      assert_equal :class, capability.type
      assert_equal [[1, :class], [2, :end]], capability.trace_points
      refute result.target_traceable?
    ensure
      trace&.disable
    end
  end

  def test_pattern_matching_operands_are_supported_and_semantic_changes_are_visible
    with_project do |project|
      baseline = fingerprint(project, pattern_source(key: "status", value_class: "Integer"))
      key_changed = fingerprint(project, pattern_source(key: "state", value_class: "Integer"))
      class_changed = fingerprint(project, pattern_source(key: "status", value_class: "Float"))

      [baseline, key_changed, class_changed].each { |result| refute result.fallback? }
      refute_equal method_digest(baseline, "extract"), method_digest(key_changed, "extract")
      refute_equal method_digest(baseline, "extract"), method_digest(class_changed, "extract")
      assert_equal method_digest(baseline, "untouched"), method_digest(key_changed, "untouched")
      assert_equal method_digest(baseline, "untouched"), method_digest(class_changed, "untouched")
    end
  end

  def test_compile_options_are_part_of_the_execution_context_signature
    skip "RubyVM::InstructionSequence is unavailable" unless Minitest::Testmon::Engine.supported?

    original = RubyVM::InstructionSequence.compile_option
    changed = original.merge(peephole_optimization: !original.fetch(:peephole_optimization))

    with_project do |project|
      baseline_engine = Minitest::Testmon::Engine.signature
      baseline_context = Minitest::Testmon::Configuration.new(cwd: project).signature
      RubyVM::InstructionSequence.compile_option = changed

      refute_equal baseline_engine, Minitest::Testmon::Engine.signature
      refute_equal baseline_context, Minitest::Testmon::Configuration.new(cwd: project).signature
      assert_equal changed, Minitest::Testmon::Engine.signature.fetch(:compile_options)
    ensure
      RubyVM::InstructionSequence.compile_option = original
    end

    assert_equal original, RubyVM::InstructionSequence.compile_option
  end

  def test_unsupported_operand_falls_back_to_the_whole_file_fingerprint
    encoder = Object.new
    encoder.define_singleton_method(:digest) do |_value|
      raise Minitest::Testmon::UnsupportedISeq, "unsupported fixture operand"
    end

    with_project do |project|
      path = write_file(File.join(project, "unsupported.rb"), "def value = 42\n")
      resolver = Minitest::Testmon::PathResolver.new(project: project)
      result = Minitest::Testmon::ISeqFingerprint.new(resolver, encoder: encoder).call(path)

      assert result.fallback?
      assert_equal :unsupported_iseq, result.reason
      assert result.file_fingerprint.known?
      assert_equal Minitest::Testmon::ContentFingerprint.call(path), result.file_fingerprint
      assert_empty result.bodies
    end
  end

  def test_anonymous_constants_remain_unsupported_operands
    error = assert_raises(Minitest::Testmon::UnsupportedISeq) do
      Minitest::Testmon::CanonicalEncoder.new.digest(Module.new)
    end

    assert_match(/anonymous ISeq constant/, error.message)
  end

  def test_ambiguous_line_ownership_is_deterministic_and_keeps_every_body
    with_project do |project|
      source = rescue_source(rescue_call: "recover", ensure_call: "cleanup")
      first = fingerprint(project, source)
      second = fingerprint(project, source)
      ensure_line = source.lines.index { |line| line.include?("cleanup(value)") } + 1
      owners = first.bodies.select { |item| item.lines.include?(ensure_line) }

      assert_equal %i[method ensure], owners.map(&:type)
      assert_equal owners.map(&:identity).uniq, owners.map(&:identity)
      assert_equal owners.map { |item| [item.identity, item.digest, item.lines] },
        second.bodies.select { |item| item.lines.include?(ensure_line) }.map { |item| [item.identity, item.digest, item.lines] }
    end
  end

  private

  def fingerprint(project, source)
    path = write_file(File.join(project, "subject.rb"), source)
    resolver = Minitest::Testmon::PathResolver.new(project: project)
    Minitest::Testmon::ISeqFingerprint.new(resolver).call(path)
  end

  def method_digest(result, label)
    result.bodies.find { |item| item.type == :method && item.label == label }.digest
  end

  def body_digest(result, type)
    result.bodies.find { |item| item.type == type }.digest
  end

  def rescue_source(rescue_call:, ensure_call:)
    <<~RUBY
      def call(value)
        target(value)
      rescue ArgumentError => error
        #{rescue_call}(error)
      ensure
        #{ensure_call}(value)
      end
    RUBY
  end

  def pattern_source(key:, value_class:)
    <<~RUBY
      def extract(payload)
        case payload
        in {#{key}: "ok", value: #{value_class} => value}
          value
        in [String => code, *]
          code
        else
          nil
        end
      end

      def untouched = 42
    RUBY
  end

  def hashes(result)
    result.bodies.map { |item| [item.type, item.label, item.digest] }
  end

  def body(result, label)
    result.bodies.find { |item| item.identity.include?(label) }
  end
end
