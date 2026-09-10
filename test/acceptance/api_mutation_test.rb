# frozen_string_literal: true

require_relative "test_helper"

class ApiMutationTest < Minitest::Test
  include ProductAcceptance

  def test_observation_only_prepends_the_direct_file_read_boundary
    require_product!

    with_project("discovery") do |project|
      probe = MinitestTestmonAcceptance::ROOT.join("probes/api_snapshot.rb")
      project.write("api_snapshot.rb", probe.read)
      clean_path = project.path.join("clean-api.json")
      active_path = project.path.join("active-api.json")

      clean_stdout, clean_stderr, clean_status = Open3.capture3(
        {"API_SNAPSHOT_PATH" => clean_path.to_s},
        RbConfig.ruby,
        "api_snapshot.rb",
        chdir: project.path.to_s
      )
      assert clean_status.success?, "clean probe failed: #{clean_stdout}\n#{clean_stderr}"

      active_stdout, active_stderr, active_status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => MinitestTestmonAcceptance::GEMFILE.to_s,
          "MINITEST_TESTMON" => "1",
          "MINITEST_TESTMON_PROJECT_ROOT" => project.path.to_s,
          "API_SNAPSHOT_PATH" => active_path.to_s
        },
        RbConfig.ruby,
        "-rbundler/setup",
        "-rminitest/testmon",
        "api_snapshot.rb",
        chdir: project.path.to_s
      )
      assert active_status.success?, "active probe failed: #{active_stdout}\n#{active_stderr}"

      clean = JSON.parse(clean_path.read)
      active_snapshot = JSON.parse(active_path.read)
      %w[File.singleton IO.singleton].each do |target|
        %w[read binread].each do |operation|
          assert_equal "Minitest::Testmon::DirectFileReads::Methods", active_snapshot.fetch(target).fetch(operation).fetch("owner")
          active_snapshot.fetch(target)[operation] = clean.fetch(target).fetch(operation)
        end
      end
      %w[File.singleton IO.singleton].each do |target|
        ancestors = active_snapshot.fetch("ancestors").fetch(target)
        assert_equal 1, ancestors.count("Minitest::Testmon::DirectFileReads::Methods")
        ancestors.delete("Minitest::Testmon::DirectFileReads::Methods")
      end
      assert_equal clean, active_snapshot,
        "observer changed File/IO/Pathname/Psych/JSON method ownership, signatures, source locations, or ancestors"
    end
  end
end
