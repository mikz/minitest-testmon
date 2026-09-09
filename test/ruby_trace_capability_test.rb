# frozen_string_literal: true

require_relative "test_helper"

class RubyTraceCapabilityTest < TestmonTestCase
  def test_rejected_capability_probe_preserves_subsequent_targeted_tracing
    with_project do |project|
      path = write_file(File.join(project, "unhookable.rb"), "module EmptyProbeTarget\nend\n")
      refute probe(project, path).target_traceable?

      block = proc { 42 }
      seen = []
      trace = TracePoint.new(:line, :call, :b_call) { |event| seen << event.event }
      trace.enable(target: RubyVM::InstructionSequence.of(block)) { assert_equal 42, block.call }
      assert_includes seen, :b_call
      assert_includes seen, :line
    end
  end

  def test_reports_an_unhookable_instruction_sequence
    with_project do |project|
      path = write_file(File.join(project, "unhookable.rb"), <<~RUBY)
        module ExactUnhookableTarget
        end
      RUBY
      result = probe(project, path)
      capability = result.unhookable_targets.find do |item|
        item.label == "<module:ExactUnhookableTarget>"
      end

      refute_nil capability
      assert_equal :class, capability.type
      assert_equal [[1, :class], [2, :end]], capability.trace_points
      refute result.target_traceable?
      assert_equal capability.signature, capability.signature
    end
  end

  def test_nested_capabilities_match_individual_serialization_with_one_tree_serialization
    with_project do |project|
      path = write_file(File.join(project, "nested.rb"), <<~RUBY)
        module NestedCapability
          class Inner
            def repeated
              2.times { |number| number + 1 }
              2.times { |number| number + 2 }
              begin
                raise "example"
              rescue RuntimeError
                -> { :rescued }.call
              ensure
                -> { :ensured }.call
              end
            end
          end
          module Empty
          end
        end
      RUBY
      resolver = Minitest::Testmon::PathResolver.new(project: project)
      original_probe = Class.new(Minitest::Testmon::RubyTraceCapabilityProbe) do
        private

        def instruction_type(iseq, _types)
          iseq.to_a[9]
        end
      end
      expected = original_probe.new(resolver).call(path)
      serializations = 0
      trace = TracePoint.new(:c_call) do |event|
        if event.defined_class == RubyVM::InstructionSequence && event.method_id == :to_a
          serializations += 1
        end
      end
      actual = trace.enable { probe(project, path) }

      refute_empty expected.unhookable_targets
      assert_equal expected.unhookable_targets.map(&:signature), actual.unhookable_targets.map(&:signature)
      assert_equal 1, serializations
      ambiguous_probe = Class.new(Minitest::Testmon::RubyTraceCapabilityProbe) do
        private

        def serialized_types(root)
          super.transform_values { nil }
        end
      end
      ambiguous = ambiguous_probe.new(resolver).call(path)
      assert_equal expected.unhookable_targets.map(&:signature), ambiguous.unhookable_targets.map(&:signature)
    ensure
      trace&.disable
    end
  end

  def test_probe_failure_is_conservatively_untraceable
    with_project do |project|
      path = write_file(File.join(project, "invalid.rb"), "def broken(\n")
      result = probe(project, path)

      refute result.target_traceable?
      assert_equal ["probe_failure"], result.unhookable_targets.map(&:identity)
    end
  end

  def test_compile_options_are_part_of_the_execution_context_signature
    original = RubyVM::InstructionSequence.compile_option
    changed = original.merge(peephole_optimization: !original.fetch(:peephole_optimization))

    with_project do |project|
      baseline = Minitest::Testmon::Configuration.new(cwd: project).signature
      RubyVM::InstructionSequence.compile_option = changed

      refute_equal baseline, Minitest::Testmon::Configuration.new(cwd: project).signature
    ensure
      RubyVM::InstructionSequence.compile_option = original
    end
  end

  private

  def probe(project, path)
    resolver = Minitest::Testmon::PathResolver.new(project: project)
    Minitest::Testmon::RubyTraceCapabilityProbe.new(resolver).call(path)
  end
end
