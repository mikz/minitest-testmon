# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class ConfiguredProviderInventoryTest < TestmonTestCase
  def test_manifest_classifies_links_and_nonregular_entries_with_pass_local_stats
    with_project do |project|
      source = write_file(File.join(project, "source.txt"), "original")
      hardlink = File.join(project, "hardlink.txt")
      link = File.join(project, "link.txt")
      directory = File.join(project, "directory")
      File.link(source, hardlink)
      File.symlink("source.txt", link)
      Dir.mkdir(directory)
      File.symlink("directory", File.join(project, "directory-link"))
      File.symlink("missing.txt", File.join(project, "broken-link"))
      socket = UNIXServer.new(File.join(project, "socket"))
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      definition = configuration.provider :files, version: 1 do
        inventory :files, root: :project, include: "*"
        facet :content, inventory: :files, digest: :content, granularity: :file
      end
      provider = Minitest::Testmon::ConfiguredProvider.new(definition)
      context = Minitest::Testmon::SnapshotContext.new(configuration)
      manifest = provider.validation_manifest(context).first
      entries = manifest[1].fetch(:files)
      regular = entries.find { |item| item[:lexical_path] == "source.txt" }
      assert_equal "file", regular.fetch(:file_type)
      assert regular.fetch(:regular)
      linked = entries.find { |item| item[:lexical_path] == "link.txt" }
      assert_equal "link", linked.fetch(:file_type)
      assert_equal "source.txt", linked.fetch(:symlink)
      assert_equal File.realpath(source), linked.fetch(:realpath)
      assert linked.fetch(:regular)
      refute entries.any? { |item| %w[directory directory-link].include?(item[:lexical_path]) }
      refute entries.find { |item| item[:lexical_path] == "socket" }.fetch(:regular)
      assert entries.any? { |item| item[:error] == "Minitest::Testmon::PathError" }
      assert_includes context.diagnostics, "non_regular"
      fingerprints = manifest[2].to_h
      assert_equal fingerprints.fetch("project:source.txt"), fingerprints.fetch("project:hardlink.txt")

      original_time = File.mtime(source)
      File.write(hardlink, "modified")
      File.utime(original_time, original_time, source)
      fresh = provider.validation_manifest(Minitest::Testmon::SnapshotContext.new(configuration)).first
      refute_equal fingerprints.fetch("project:source.txt"), fresh[2].to_h.fetch("project:source.txt")
      File.unlink(link)
      File.symlink("hardlink.txt", link)
      retargeted = provider.validation_manifest(Minitest::Testmon::SnapshotContext.new(configuration)).first
      assert_equal "hardlink.txt", retargeted[1].fetch(:files).find { |item| item[:lexical_path] == "link.txt" }.fetch(:symlink)
    ensure
      socket&.close
    end
  end

  def test_regular_manifest_entries_do_not_repeat_file_type_queries
    with_project do |project|
      path = write_file(File.join(project, "source.txt"), "original")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      definition = configuration.provider :files, version: 1 do
        inventory :files, root: :project, include: "*.txt"
        facet :content, inventory: :files, digest: :content, granularity: :file
      end
      provider = Minitest::Testmon::ConfiguredProvider.new(definition)
      context = Minitest::Testmon::SnapshotContext.new(configuration)
      provider.instance_variable_set(:@resolver, context.resolver)
      locator = context.resolver.resolve(path)
      original_file = File.method(:file?)
      original_directory = File.method(:directory?)
      queries = []
      File.define_singleton_method(:file?) do |value|
        queries << [:file, value]
        original_file.call(value)
      end
      File.define_singleton_method(:directory?) do |value|
        queries << [:directory, value]
        original_directory.call(value)
      end
      result = provider.send(:inventory_manifest, definition.inventories.first, [locator], context, [path], {path => locator})
      assert result.fetch(:files).first.fetch(:regular)
      assert_empty queries.select { |_, value| value == path }
    ensure
      File.define_singleton_method(:file?, original_file) if original_file
      File.define_singleton_method(:directory?, original_directory) if original_directory
    end
  end
end
