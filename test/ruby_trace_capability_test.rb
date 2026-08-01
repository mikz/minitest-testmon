# frozen_string_literal: true

require_relative "test_helper"

class RubyTraceCapabilityTest < TestmonTestCase
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
