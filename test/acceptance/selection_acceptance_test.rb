# frozen_string_literal: true

require_relative "test_helper"

class SelectionAcceptanceTest < Minitest::Test
  include ProductAcceptance

  def test_iseq_fingerprint_ignores_comments_whitespace_and_source_line_moves
    require_product!

    with_project("selection") do |project|
      baseline = learn_baseline(project)
      alpha_id = find_test_id(baseline, "test_alpha")
      beta_id = find_test_id(baseline, "test_beta")

      original = project.read("lib/subject.rb")
      project.write("lib/subject.rb", "# moved without semantic change\n\n\n#{original}")

      result = driver.run(project)
      assert result.success?, result.stderr
      report = driver.report(project)
      assert_report_contract report
      refute_includes report.dig("tests", "selected"), alpha_id
      refute_includes report.dig("tests", "selected"), beta_id
      assert_empty report.dig("tests", "selected")
    end
  end

  def test_iseq_semantic_change_selects_only_its_consumers
    require_product!

    with_project("selection") do |project|
      baseline = learn_baseline(project)
      alpha_id = find_test_id(baseline, "test_alpha")
      beta_id = find_test_id(baseline, "test_beta")
      exact_id = find_test_id(baseline, "test_exact_file_input")

      project.write("lib/subject.rb", project.read("lib/subject.rb").sub("1 + 1", "1 + 2"))
      result = driver.run(project)
      refute result.success?, "semantic mutant should fail its known assertion"
      report = driver.report(project)
      assert_report_contract report
      assert_equal [alpha_id], report.dig("tests", "selected")
      assert_equal [alpha_id], report.dig("tests", "executed")
      refute_includes report.dig("tests", "selected"), beta_id
      refute_includes report.dig("tests", "selected"), exact_id

      full_stdout, full_stderr, full_status = run_selector_disabled(project)
      refute full_status.success?, "selector-disabled oracle did not fail for semantic mutant"
      assert_match(/test_alpha/, "#{full_stdout}\n#{full_stderr}")

      explanation = driver.explain(project, alpha_id)
      assert explanation.success?, explanation.stderr
      assert_includes "#{explanation.stdout}\n#{explanation.stderr}", alpha_id
      assert_match(/subject\.rb|ruby_iseq/, "#{explanation.stdout}\n#{explanation.stderr}")
    end
  end

  def test_exact_file_mutation_oracle_selects_the_known_failing_test
    require_product!

    with_project("selection") do |project|
      baseline = learn_baseline(project)
      exact_id = find_test_id(baseline, "test_exact_file_input")
      alpha_id = find_test_id(baseline, "test_alpha")
      beta_id = find_test_id(baseline, "test_beta")

      project.write("data/exact.txt", "exact-v2\n")
      result = driver.run(project)
      refute result.success?, "exact-file mutant should fail its known assertion"
      report = driver.report(project)
      assert_report_contract report
      MinitestTestmonAcceptance::Golden.assert_selection_sound!(report, [exact_id])
      assert_equal [exact_id], report.dig("tests", "selected")
      refute_includes report.dig("tests", "selected"), alpha_id
      refute_includes report.dig("tests", "selected"), beta_id

      full_stdout, full_stderr, full_status = run_selector_disabled(project)
      refute full_status.success?, "selector-disabled oracle did not fail for exact-file mutant"
      assert_match(/test_exact_file_input/, "#{full_stdout}\n#{full_stderr}")
    end
  end

  def test_iseq_sibling_semantic_change_selects_the_sibling_consumer_only
    require_product!

    with_project("selection") do |project|
      baseline = learn_baseline(project)
      alpha_id = find_test_id(baseline, "test_alpha")
      beta_id = find_test_id(baseline, "test_beta")
      exact_id = find_test_id(baseline, "test_exact_file_input")

      project.write("lib/subject.rb", project.read("lib/subject.rb").sub("2 + 2", "2 + 3"))
      result = driver.run(project)
      refute result.success?, "sibling semantic mutant should fail its known assertion"
      report = driver.report(project)
      assert_report_contract report
      assert_equal [beta_id], report.dig("tests", "selected")
      refute_includes report.dig("tests", "selected"), alpha_id
      refute_includes report.dig("tests", "selected"), exact_id

      full_stdout, full_stderr, full_status = run_selector_disabled(project)
      refute full_status.success?, "selector-disabled oracle did not fail for sibling mutant"
      assert_match(/test_beta/, "#{full_stdout}\n#{full_stderr}")
    end
  end

  def test_discovery_ignores_an_existing_selective_cache_and_executes_every_test
    require_product!

    with_project("selection") do |project|
      baseline = learn_baseline(project)
      result = driver.discover(project)
      assert result.success?, result.stderr
      report = driver.report(project)
      assert_report_contract report
      MinitestTestmonAcceptance::Golden.assert_full_discovery!(report)
      assert_equal baseline.dig("tests", "discovered"), report.dig("tests", "executed")
    end
  end

  private

  def learn_baseline(project)
    result = driver.run(project)
    assert result.success?, result.stderr
    report = driver.report(project)
    assert_report_contract report
    assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
    assert_equal true, report.dig("publication", "published")
    assert driver.state_path(project).file?, "baseline did not create the frozen public state path"
    report
  end
end
