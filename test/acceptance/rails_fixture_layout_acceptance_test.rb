# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsFixtureLayoutAcceptanceTest < Minitest::Test
  include RailsProductAcceptance

  TEST_ID = "ClassFixtureLayoutTest#test_uses_class_fixture_order"

  def test_class_fixture_layout_publishes_reuses_and_invalidates_in_serial_and_process_runs
    [1, 2].each do |workers|
      with_rails_project(workers: workers) do |project, runtime|
        project.path.glob("test/**/*_test.rb").each(&:delete)
        project.write("native/first/widgets.yml", "one:\n  name: First fixture\n")
        project.write("native/second/widgets.yml", "one:\n  name: Second fixture\n")
        project.write("test/models/class_fixture_layout_test.rb", <<~RUBY)
          require_relative "../test_helper"

          class ClassFixtureLayoutTest < ActiveSupport::TestCase
            paths = [Rails.root.join("native/first"), Rails.root.join("native/second")]
            paths.reverse! if ENV["FIXTURE_LAYOUT_REVERSED"] == "1"
            self.fixture_paths = paths
            fixtures :widgets

            def test_uses_class_fixture_order
              expected = ENV["FIXTURE_LAYOUT_REVERSED"] == "1" ? "First fixture" : "Second fixture"
              assert_equal expected, widgets(:one).name
            end
          end
        RUBY

        baseline = run_layout(project, runtime)
        assert_equal [TEST_ID], baseline.dig("tests", "executed")
        fixture_claims = baseline.dig("inventory", "claimed", "items").select { |item| item["provider"] == "rails.fixtures@2" }
        assert_equal ["project:native/first/widgets.yml", "project:native/second/widgets.yml"], fixture_claims.map { |item| item.fetch("path") }.sort
        warm = run_layout(project, runtime)
        assert_empty warm.dig("tests", "selected")
        assert_empty warm.dig("tests", "executed")

        # Change runtime layout only: no source edits or cache resets can explain
        # the required invalidation of this previously cached test.
        reversed = run_layout(project, runtime, reversed: true)
        refute_equal baseline.fetch("context_signature"), reversed.fetch("context_signature")
        assert_equal [TEST_ID], reversed.dig("tests", "selected")
        assert_equal [TEST_ID], reversed.dig("tests", "executed")
        warm_reversed = run_layout(project, runtime, reversed: true)
        assert_empty warm_reversed.dig("tests", "selected")
        assert_empty warm_reversed.dig("tests", "executed")
      end
    end
  end

  private

  def run_layout(project, runtime, reversed: false)
    result = driver.run(project, env: runtime.env.merge("FIXTURE_LAYOUT_REVERSED" => reversed ? "1" : "0"))
    assert result.success?, "fixture layout run failed: #{result.stdout}\n#{result.stderr}"
    report = driver.report(project)
    assert_report_contract report
    assert_equal true, report.fetch("complete"), {diagnostics: report.fetch("diagnostics"), publication: report.fetch("publication"), checkpoints: report["checkpoints"], unresolved: report.dig("inventory", "unresolved"), stderr: result.stderr}.inspect
    assert_equal true, report.dig("publication", "published"), report.fetch("publication").inspect
    report
  end
end
