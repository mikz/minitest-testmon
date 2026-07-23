# frozen_string_literal: true

require "minitest/autorun"
# standard:disable Lint/RedundantRequireStatement
require "pathname"
# standard:enable Lint/RedundantRequireStatement

# This fixture must exercise the exact APIs that the observer promises to see.
# standard:disable Style/FileRead, Style/FileWrite

class DiscoveryTest < Minitest::Test
  ROOT = Pathname.new(File.expand_path("..", __dir__))

  def test_file_new_existing_read_candidate
    file = File.new(ROOT.join("data/existing.txt"), "r")
    assert_equal "existing-input\n", file.read
  ensure
    file&.close
  end

  def test_file_open_existing_read_candidate
    contents = File.open(ROOT.join("data/existing.txt"), "r", &:read)
    assert_equal "existing-input\n", contents
  end

  def test_file_open_nonexistent_read_candidate
    assert_raises(Errno::ENOENT) do
      File.open(ROOT.join("data/does-not-exist.txt"), "r", &:read)
    end
  end

  def test_file_open_existing_write_only_candidate
    File.open(ROOT.join("data/write-only.txt"), "w") do |file|
      file.write("written-during-discovery\n")
    end
    assert_equal "written-during-discovery\n", ROOT.join("data/write-only.txt").read
  end

  def test_source_race_is_not_filtered_as_nonexistent
    path = ROOT.join("data/racy.txt")
    assert_equal "disappears-after-read\n", File.open(path, "r", &:read)
    path.delete
    refute_path_exists path
  end

  def test_direct_c_file_read_is_visible_as_unresolved
    assert_equal "direct-c-read\n", File.read(ROOT.join("data/direct.txt"))
  end

  def test_require_argument_is_observed
    require ROOT.join("lib/loaded_feature").to_s
    assert_equal "loaded", LOADED_FEATURE_VALUE
  end

  def test_load_argument_is_observed
    load ROOT.join("lib/reloaded_feature.rb").to_s
    assert_equal "reloaded", RELOADED_FEATURE_VALUE
  end

  def test_failure_does_not_stop_discovery
    flunk "planted discovery failure" if ENV["PLANT_DISCOVERY_FAILURE"] == "1"
    pass
  end

  def test_after_planted_failure_still_executes
    assert true
  end
end
# standard:enable Style/FileRead, Style/FileWrite
