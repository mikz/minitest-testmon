# frozen_string_literal: true

require_relative "test_helper"

class InventoryGlobTest < TestmonTestCase
  Inventory = Struct.new(:base, :root, :include_patterns, :exclude_patterns)

  def test_recursive_patterns_preserve_order_hidden_entries_and_symlinks
    with_tree do |project|
      %w[**/*.rb **/*].each do |pattern|
        assert_parity(project, [pattern], %w[vendor/**/* node_modules/**/* .git/**/* excluded.rb/**/*])
      end
      assert_parity(project, ["**/*.rb", "lib/**/*", "**/*"], %w[vendor/**/* node_modules/**/*])
    end
  end

  def test_custom_patterns_and_explicit_symlink_prefixes_preserve_glob_behavior
    with_tree do |project|
      assert_parity(project,
        ["**/*.rb", "link/*.rb", "lib/{z,a}.rb", "lib/../vendor/*.rb"],
        ["vendor/**/*", "lib/{z,.hidden}.rb", "link/**/*", "lib/../node_modules/**/*"])
    end
  end

  def test_metacharacter_base_uses_original_glob
    with_tree do |project|
      base = File.join(project, "[ab]")
      FileUtils.mkdir_p(base)
      write_file(File.join(project, "a/keep.rb"), "value")
      assert_parity(project, ["**/*.rb"], ["vendor/**/*"], base: "[ab]")
    end
  end

  def test_excluded_subtrees_are_never_globbed
    with_tree do |project|
      provider, inventory = subject(project, ["**/*"], %w[vendor/**/* node_modules/**/* .git/**/*])
      original = Dir.method(:glob)
      calls = []
      begin
        Dir.define_singleton_method(:glob) do |*args, **kwargs, &block|
          calls << [args.first, kwargs[:base]]
          original.call(*args, **kwargs, &block)
        end
        actual = provider.send(:inventory_paths, inventory)
      ensure
        Dir.define_singleton_method(:glob, original)
      end
      refute_includes actual, File.join(project, "vendor")
      refute calls.any? { |pattern, base| pattern == File.join(project, "**/*") }, calls.inspect
      %w[vendor node_modules .git].each do |name|
        prefix = File.join(project, name)
        refute calls.any? { |pattern, base| pattern.start_with?("#{prefix}/") || base == prefix }, calls.inspect
      end
    end
  end

  def test_membership_is_refreshed_between_enumerations
    with_tree do |project|
      provider, inventory = subject(project, ["**/*.rb"], ["vendor/**/*"])
      before = provider.send(:inventory_paths, inventory)
      added = write_file(File.join(project, "new/.added.rb"), "value")
      after = provider.send(:inventory_paths, inventory)
      refute_includes before, added
      assert_includes after, added
    end
  end

  def test_missing_and_file_bases_preserve_empty_glob_results
    with_tree do |project|
      ["missing", "root.rb"].each do |base|
        %w[**/*.rb **/*].each do |pattern|
          assert_parity(project, [pattern], ["vendor/**/*"], base: base)
        end
      end
    end
  end

  private

  def with_tree
    with_project do |project|
      project = File.realpath(project)
      %w[root.rb .hidden.rb lib/z.rb lib/a.rb lib/.hidden.rb .hidden/nested.rb
        vendor/deep/private.rb node_modules/deep/package.rb .git/objects/private.rb
        excluded.rb/deep/private.rb bracket[dir]/file.rb brace{dir}/file.rb
        targets/linked.rb].each { |name| write_file(File.join(project, name), "value") }
      File.symlink("targets", File.join(project, "link"))
      File.symlink("root.rb", File.join(project, "alias.rb"))
      yield project
    end
  end

  def subject(project, includes, excludes, base: ".")
    provider = Minitest::Testmon::ConfiguredProvider.allocate
    provider.instance_variable_set(:@resolver, Minitest::Testmon::PathResolver.new(project: project))
    inventory = Inventory.new(base: base, root: :project, include_patterns: includes, exclude_patterns: excludes)
    [provider, inventory]
  end

  def assert_parity(project, includes, excludes, base: ".")
    provider, inventory = subject(project, includes, excludes, base: base)
    directory = File.expand_path(base, project)
    included = includes.flat_map { |pattern| Dir.glob(File.join(directory, pattern), File::FNM_DOTMATCH) }.uniq
    excluded = excludes.flat_map { |pattern| Dir.glob(File.join(directory, pattern), File::FNM_DOTMATCH) }
      .to_h { |path| [File.expand_path(path), true] }
    expected = included.reject { |path| excluded.key?(File.expand_path(path)) }
    assert_equal expected, provider.send(:inventory_paths, inventory)
  end
end
