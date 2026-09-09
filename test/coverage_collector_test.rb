# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class CoverageCollectorTest < TestmonTestCase
  def test_only_positive_line_deltas_resolve_paths
    with_project do |project|
      changed = write_file(File.join(project, "changed.rb"), "42\n")
      unchanged = write_file(File.join(project, "unchanged.rb"), "42\n")
      reset = write_file(File.join(project, "reset.rb"), "42\n")
      branches = write_file(File.join(project, "branches.rb"), "42\n")
      resolver = Minitest::Testmon::PathResolver.new(project: project)
      original = resolver.method(:resolve)
      resolved = []
      resolver.define_singleton_method(:resolve) do |path|
        resolved << path
        original.call(path)
      end
      collector = build_collector(resolver: resolver)
      before = {changed => [nil, 1, 0], unchanged => [1], reset => [4], branches => {branches: {a: 1}}}
      after = {changed => [nil, 2, 1], unchanged => [1], reset => [0], branches => {branches: {a: 2}}}

      assert_equal({changed => [2, 3]}, collector.send(:coverage_delta, before, after))
      assert_equal [changed], resolved
    end
  end

  def test_new_sources_and_hash_line_entries_keep_exact_changed_lines
    with_project do |project|
      path = write_file(File.join(project, "source.rb"), "42\n")
      collector = build_collector(resolver: Minitest::Testmon::PathResolver.new(project: project))
      assert_equal({path => [2, 4]}, collector.send(:coverage_delta, {}, {path => {lines: [nil, 1, 0, 2], branches: {}}}))
      assert_equal({path => [3]}, collector.send(:coverage_delta, {path => {lines: [nil, 1]}}, {path => {lines: [nil, 1, 2]}}))
    end
  end

  def test_symlink_retargets_are_resolved_fresh_without_inventing_execution
    with_project do |project|
      first = write_file(File.join(project, "first.rb"), "42\n")
      second = write_file(File.join(project, "second.rb"), "42\n")
      link = File.join(project, "alias.rb")
      File.symlink(first, link)
      collector = build_collector(
        resolver: Minitest::Testmon::PathResolver.new(project: project), allowed_paths: [File.realpath(first)]
      )
      assert_equal({link => [1]}, collector.send(:coverage_delta, {link => [0]}, {link => [1]}))
      File.unlink(link)
      File.symlink(second, link)
      assert_empty collector.send(:coverage_delta, {link => [1]}, {link => [2]})
      File.unlink(link)
      File.symlink(first, link)
      assert_empty collector.send(:coverage_delta, {link => [2]}, {link => [2]})
      assert_equal({link => [1]}, collector.send(:coverage_delta, {link => [2]}, {link => [3]}))
    end
  end

  def test_changed_paths_outside_allowed_roots_are_rejected
    with_project do |project|
      Dir.mktmpdir do |outside|
        path = write_file(File.join(outside, "source.rb"), "42\n")
        collector = build_collector(resolver: Minitest::Testmon::PathResolver.new(project: project))
        assert_empty collector.send(:coverage_delta, {path => [0]}, {path => [1]})
      end
    end
  end

  def test_mri_snapshots_are_independent_and_preserve_existing_coverage
    with_project do |project|
      source = write_file(File.join(project, "source.rb"), "def coverage_collector_probe\n  42\nend\n")
      script = <<~CODE
        require "coverage"
        require "minitest/testmon"
        Coverage.start(lines: true, branches: true)
        load ARGV.fetch(0)
        session = Object.new
        def session.record(*) = raise("unexpected diagnostic")
        collector = Minitest::Testmon::CoverageCollector.new(
          session,
          resolver: Minitest::Testmon::PathResolver.new(project: File.dirname(ARGV.fetch(0)))
        )
        before = collector.send(:snapshot)
        saved = before.fetch(ARGV.fetch(0)).fetch(:lines).dup
        coverage_collector_probe
        after = collector.send(:snapshot)
        raise "snapshot mutated" unless before.fetch(ARGV.fetch(0)).fetch(:lines) == saved
        raise "counter arrays reused" if before.fetch(ARGV.fetch(0)).fetch(:lines).equal?(after.fetch(ARGV.fetch(0)).fetch(:lines))
        raise "missing execution" unless after.fetch(ARGV.fetch(0)).fetch(:lines)[1] > saved[1].to_i
        collector.send(:coverage_delta, before, after)
        raise "coverage stopped" unless Coverage.running?
        raise "coverage mode changed" unless Coverage.peek_result.fetch(ARGV.fetch(0)).key?(:branches)
        raise "coverage counters changed" unless Coverage.peek_result.fetch(ARGV.fetch(0)) == after.fetch(ARGV.fetch(0))
        puts "ok"
      CODE
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, source)
      assert status.success?, stderr
      assert_equal "ok\n", stdout
    end
  end

  private

  def build_collector(resolver:, allowed_paths: nil)
    collector = Minitest::Testmon::CoverageCollector.allocate
    collector.instance_variable_set(:@resolver, resolver)
    collector.instance_variable_set(:@allowed_roots, [:project])
    collector.instance_variable_set(:@allowed_paths, allowed_paths&.to_h { |path| [path, true] })
    collector
  end
end
