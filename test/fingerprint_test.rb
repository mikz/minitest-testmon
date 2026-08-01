# frozen_string_literal: true

require_relative "test_helper"

class FingerprintTest < TestmonTestCase
  def test_content_distinguishes_known_empty_missing_and_unknown
    with_project do |project|
      empty = write_file(File.join(project, "empty.bin"), "")
      known = Minitest::Testmon::ContentFingerprint.call(empty)
      missing = Minitest::Testmon::ContentFingerprint.call(File.join(project, "missing.bin"))
      directory = Minitest::Testmon::ContentFingerprint.call(project)

      assert known.known?
      assert missing.missing?
      assert directory.unknown?
      refute_equal known.digest, missing.digest
    end
  end

  def test_path_resolver_uses_most_specific_root_and_rejects_outside
    with_project do |project|
      engine = File.join(project, "engines", "billing")
      FileUtils.mkdir_p(engine)
      file = write_file(File.join(engine, "model.rb"), "nil\n")
      resolver = Minitest::Testmon::PathResolver.new(project: project, engine: engine)

      locator = resolver.resolve(file)
      assert_equal :engine, locator.root
      assert_equal "model.rb", locator.relative_path
      assert_raises(Minitest::Testmon::PathError) { resolver.resolve(__FILE__) }
    end
  end

  def test_path_resolver_canonicalizes_missing_paths_through_the_nearest_existing_ancestor
    with_project do |project|
      outside = Dir.mktmpdir("minitest-testmon-outside")
      File.symlink(outside, File.join(project, "escaped"))
      resolver = Minitest::Testmon::PathResolver.new(project: project)

      assert_raises(Minitest::Testmon::PathError) do
        resolver.resolve(File.join(project, "escaped", "missing", "artifact.yml"))
      end

      locator = resolver.resolve(File.join(project, "missing", "nested", "artifact.yml"))
      assert_equal :project, locator.root
      assert_equal "missing/nested/artifact.yml", locator.relative_path
      assert_equal File.join(File.realpath(project), "missing", "nested", "artifact.yml"), locator.absolute_path
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end
end
