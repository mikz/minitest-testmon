# frozen_string_literal: true

require_relative "test_helper"

class RubyPathPolicyTest < TestmonTestCase
  def test_project_ruby_uses_the_same_default_exclusions_as_inventory
    with_project do |project|
      application = write_file(File.join(project, "app/value.rb"), "VALUE = 1\n")
      dependency = write_file(File.join(project, "vendor/bundle/ruby/4.0.0/gems/example/lib/example.rb"), "EXAMPLE = 1\n")
      temporary = write_file(File.join(project, "tmp/generated.rb"), "GENERATED = 1\n")
      policy = policy_for(project)

      assert_equal File.realpath(application), policy.locator(application).absolute_path
      assert_nil policy.locator(dependency)
      assert_nil policy.locator(temporary)
      assert_includes policy.include_patterns(:project), "**/*.rb"
      assert_includes policy.exclude_patterns(:project), "vendor/**/*"
    end
  end

  def test_named_root_requires_an_explicit_ruby_pattern
    with_project do |project|
      shared = File.join(project, "shared")
      configured = write_file(File.join(shared, "components/value.rb"), "VALUE = 1\n")
      outside_pattern = write_file(File.join(shared, "other/value.rb"), "VALUE = 2\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.root :shared, shared
      configuration.ruby_files "components/**/*.rb", root: :shared
      policy = Minitest::Testmon::RubyPathPolicy.new(configuration)

      assert_equal File.realpath(configured), policy.locator(configured).absolute_path
      assert_nil policy.locator(outside_pattern)
    end
  end

  def test_canonical_vendor_target_is_excluded_through_a_project_symlink
    with_project do |project|
      dependency = write_file(File.join(project, "vendor/bundle/ruby/4.0.0/gems/example/lib/example.rb"), "EXAMPLE = 1\n")
      link = File.join(project, "lib/example.rb")
      FileUtils.mkdir_p(File.dirname(link))
      File.symlink(dependency, link)

      assert_nil policy_for(project).locator(link)
    end
  end

  def test_project_callsite_does_not_require_a_ruby_filename
    with_project do |project|
      rakefile = write_file(File.join(project, "Rakefile"), "task :default\n")
      dependency = write_file(File.join(project, "vendor/bundle/gems/example/Rakefile"), "task :default\n")
      policy = policy_for(project)

      assert_equal File.realpath(rakefile), policy.project_locator(rakefile).absolute_path
      assert_nil policy.project_locator(dependency)
    end
  end

  private

  def policy_for(project)
    configuration = Minitest::Testmon::Configuration.new(cwd: project)
    Minitest::Testmon::RubyPathPolicy.new(configuration)
  end
end
