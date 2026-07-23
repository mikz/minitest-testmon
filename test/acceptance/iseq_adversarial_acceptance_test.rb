# frozen_string_literal: true

require_relative "test_helper"

class IseqAdversarialAcceptanceTest < Minitest::Test
  include ProductAcceptance

  def test_string_literal_operand_change_selects_its_consumer
    assert_behavioral_mutation(
      before: '"literal-v1"',
      after: '"literal-v2"',
      test_fragment: "SelectionTest#test_string_literal"
    )
  end

  def test_send_target_operand_change_selects_its_consumer
    assert_behavioral_mutation(
      before: "    helper_one\n",
      after: "    helper_two\n",
      test_fragment: "SelectionTest#test_dispatch_operand"
    )
  end

  def test_nested_block_operand_change_selects_its_consumer
    assert_behavioral_mutation(
      before: "value * 2",
      after: "value * 3",
      test_fragment: "SelectionTest#test_nested_block_operand"
    )
  end

  def test_branch_comparison_operand_change_selects_its_consumer
    assert_behavioral_mutation(
      before: "value > 1",
      after: "value > 2",
      test_fragment: "SelectionTest#test_branch_operand"
    )
  end

  def test_top_level_iseq_uses_explicit_whole_file_fallback
    with_project("selection") do |project|
      baseline = learn_baseline(project)
      target_id = find_test_id(baseline, "SelectionTest#test_top_level_fallback")
      project.write(
        "lib/top_level_fallback.rb",
        project.read("lib/top_level_fallback.rb").sub("VALUE = 10", "VALUE = 11")
      )

      result = driver.run(project)
      refute result.success?, "top-level ISeq mutant unexpectedly passed"
      report = driver.report(project)
      assert_report_contract report
      assert_equal [target_id], report.dig("tests", "selected")
      fallback = report.fetch("inventory").values.flat_map { |category| category.fetch("items") }.select do |item|
        item.fetch("path")&.end_with?("lib/top_level_fallback.rb") &&
          item.fetch("reason") == "whole_file_fallback"
      end
      refute_empty fallback, "top-level executable code was not reported as whole-file fallback"
    end
  end

  private

  def assert_behavioral_mutation(before:, after:, test_fragment:)
    with_project("selection") do |project|
      baseline = learn_baseline(project)
      target_id = find_test_id(baseline, test_fragment)
      original = project.read("lib/subject.rb")
      changed = original.sub(before, after)
      refute_equal original, changed, "fixture mutation did not find #{before.inspect}"
      project.write("lib/subject.rb", changed)

      result = driver.run(project)
      refute result.success?, "behavioral ISeq mutant unexpectedly passed"
      report = driver.report(project)
      assert_report_contract report
      assert_equal [target_id], report.dig("tests", "selected")

      stdout, stderr, status = run_selector_disabled(project)
      refute status.success?, "selector-disabled oracle did not expose ISeq mutant"
      assert_includes "#{stdout}\n#{stderr}", test_fragment.split("#").last
    end
  end

  def learn_baseline(project)
    result = driver.run(project)
    assert result.success?, result.stderr
    report = driver.report(project)
    assert_report_contract report
    assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
    assert_equal true, report.dig("publication", "published")
    report
  end
end
