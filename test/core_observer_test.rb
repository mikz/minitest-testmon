# frozen_string_literal: true

require_relative "test_helper"

class CoreObserverTest < TestmonTestCase
  def test_file_object_is_resolved_and_direct_c_read_is_unresolved
    with_project do |project|
      data = write_file(File.join(project, "data.txt"), "value")
      script = write_file(File.join(project, "read.rb"), <<~RUBY)
        File.read(#{data.dump})
        File.open(#{data.dump}) { |file| file.read }
      RUBY
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project)
      ).start
      Minitest::Testmon::ExecutionContext.with_test("ObserverTest#test_read") { load script }
      observer.close

      opaque = session.observations.find { |item| item.reason == :opaque_c_call }
      exact = session.observations.find { |item| item.kind == :file_read && item.path == File.realpath(data) }
      construction = session.observations.find { |item| item.reason == :conservative_file_construction }
      refute_nil opaque
      refute_nil exact
      refute_nil construction
      assert_equal({path: "project:read.rb", line: 1, owner: "#<Class:IO>"}, opaque.callsite)
    end
  end

  def test_project_execution_on_an_unattributed_thread_during_a_test_is_suite_scoped
    with_project do |project|
      script = write_file(File.join(project, "background.rb"), "BACKGROUND_VALUE = 1\n")
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        test_only: true,
        observe_files: false,
        boundary_tracker: Struct.new(:boundary_active?).new(true)
      ).start

      Thread.new { load script }.join
      observer.close

      ambiguous = session.observations.find { |item| item.operation == :unattributed_thread }
      refute_nil ambiguous
      assert_equal :late_activation, ambiguous.reason
      assert_equal :suite, ambiguous.scope
      assert_empty session.diagnostics
    end
  end

  def test_constant_read_maps_back_to_the_declaring_ruby_file
    with_project do |project|
      declaration = write_file(File.join(project, "declared.rb"), "TESTMON_DECLARED_VALUE = 7\n")
      reader = write_file(File.join(project, "reader.rb"), "TESTMON_DECLARED_VALUE\n")
      load declaration
      session = RecordingSession.new
      tracker = Struct.new(:boundary_active?).new(false)
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        test_only: true,
        observe_files: false,
        boundary_tracker: tracker
      ).start

      Minitest::Testmon::ExecutionContext.with_test("ConstantTest#test_read") { load reader }
      observer.close

      observation = session.observations.find { |item| item.operation == :constant_read }
      refute_nil observation
      assert_equal File.realpath(declaration), observation.path
      assert_equal [1], observation.details.fetch(:lines)
    ensure
      Object.send(:remove_const, :TESTMON_DECLARED_VALUE) if Object.const_defined?(:TESTMON_DECLARED_VALUE, false)
    end
  end

  def test_configured_ruby_paths_are_canonicalized_once_and_then_served_from_the_allowlist
    with_project do |project|
      script = write_file(File.join(project, "reader.rb"), "VALUE = 1\n")
      resolver = CountingResolver.new(Minitest::Testmon::PathResolver.new(project: project))
      observer = Minitest::Testmon::CoreObserver.new(
        RecordingSession.new,
        resolver: resolver,
        ruby_paths: [script],
        observe_files: false
      )

      assert_equal File.realpath(script), observer.send(:ruby_locator, script).absolute_path
      assert_equal File.realpath(script), observer.send(:ruby_locator, script).absolute_path
      assert_nil observer.send(:ruby_locator, File.join(project, "other.rb"))
      assert_equal 1, resolver.resolve_count
    end
  end

  def test_preloaded_project_method_uses_a_targeted_trace
    with_project do |project|
      script = write_file(File.join(project, "preloaded.rb"), <<~RUBY)
        class TestmonPreloadedTarget
          def self.call
            :called
          end
        end
      RUBY
      load script
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        ruby_paths: [script],
        test_only: true,
        observe_files: false,
        boundary_tracker: Struct.new(:boundary_active?).new(false)
      ).start

      Minitest::Testmon::ExecutionContext.with_test("TargetTest#test_call") do
        TestmonPreloadedTarget.call
      end
      observer.close

      observation = session.observations.find { |item| item.operation == :tracepoint_call }
      refute_nil observation
      assert_equal File.realpath(script), observation.path
    ensure
      Object.send(:remove_const, :TestmonPreloadedTarget) if Object.const_defined?(:TestmonPreloadedTarget, false)
    end
  end

  def test_comment_only_ruby_file_is_observed_without_a_target_trace
    with_project do |project|
      script = write_file(File.join(project, "empty_initializer.rb"), "# Configuration intentionally left blank.\n")
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        ruby_paths: [script],
        observe_files: false
      ).start

      load script
      observer.close

      observation = session.observations.find do |item|
        item.kind == :ruby_script && item.path == File.realpath(script)
      end
      refute_nil observation
      refute session.observations.any? { |item| item.kind == :provider_error }
    end
  end

  def test_unhookable_source_is_presealed_suite_scoped_and_never_raises
    with_project do |project|
      script = write_file(File.join(project, "lib", "unhookable.rb"), <<~RUBY)
        module TestmonUnhookableTarget
        end
      RUBY
      snapshot = ruby_snapshot(project)
      source_artifacts = snapshot.context.artifacts.select do |artifact|
        artifact.relative_path == "lib/unhookable.rb" && artifact.facet == "ruby_iseq"
      end

      refute_empty source_artifacts
      assert source_artifacts.all? { |artifact| artifact.scope == :suite }
      assert source_artifacts.all? { |artifact| artifact.reason.nil? }
      assert_equal [File.realpath(script)], snapshot.ruby_unhookable_paths
      capability = snapshot.context.capabilities.fetch(0)
      assert_equal "project:lib/unhookable.rb", capability.fetch(:source)
      assert_equal %w[line call], capability.fetch(:requested_events)
      assert_equal(
        [[1, "class"], [2, "end"]],
        capability.fetch(:unhookable).fetch(0).fetch(:trace_points)
      )

      session = snapshot.observe(mode: :discover)
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: snapshot.context.resolver,
        allowed_roots: snapshot.ruby_inventory_roots,
        ruby_paths: snapshot.ruby_inventory_paths,
        unhookable_ruby_paths: snapshot.ruby_unhookable_paths,
        test_only: true,
        observe_files: false,
        boundary_tracker: Minitest::Testmon::ExecutionContext
      ).start
      session.attach_observer(observer)

      Minitest::Testmon::ExecutionContext.with_test("CapabilityTest#test_load") { load script }
      report = session.finalize

      assert report.complete?
      refute report.observations.any? { |item| item.kind == :provider_error }
      suite_keys = report.dependencies.filter_map do |dependency|
        dependency.artifact_key if dependency.test_id == "*"
      end
      assert_empty source_artifacts.map(&:key) - suite_keys

      write_file(script, "def testmon_traceable_call\n  1\nend\n")
      traceable_snapshot = ruby_snapshot(project)
      assert_empty traceable_snapshot.ruby_unhookable_paths
      refute_equal snapshot.signature, traceable_snapshot.signature
    ensure
      Object.send(:remove_const, :TestmonUnhookableTarget) if Object.const_defined?(:TestmonUnhookableTarget, false)
      Object.send(:remove_method, :testmon_traceable_call) if Object.private_method_defined?(:testmon_traceable_call)
    end
  end

  def test_sealed_ruby_inventory_targets_preloaded_config_code_on_a_background_thread
    with_project do |project|
      script = write_file(File.join(project, "config", "ci.rb"), <<~RUBY)
        module TestmonConfigCiTarget
          def self.call
            :configured
          end
        end
      RUBY
      load script
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)

      assert_includes snapshot.ruby_inventory_paths, File.realpath(script)
      assert_includes snapshot.ruby_inventory_roots, :project

      session = snapshot.observe(mode: :discover)
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: snapshot.context.resolver,
        allowed_roots: snapshot.ruby_inventory_roots,
        ruby_paths: snapshot.ruby_inventory_paths,
        test_only: true,
        observe_files: false,
        boundary_tracker: Minitest::Testmon::ExecutionContext
      ).start
      session.attach_observer(observer)

      Minitest::Testmon::ExecutionContext.begin_boundary
      Thread.new { TestmonConfigCiTarget.call }.join
      Minitest::Testmon::ExecutionContext.end_boundary
      report = session.finalize

      observation = report.observations.find do |item|
        item.operation == :unattributed_thread && item.path == File.realpath(script)
      end
      refute_nil observation
      assert_equal :late_activation, observation.reason
      claimed_keys = report.dependencies.filter_map do |dependency|
        dependency.artifact_key if dependency.test_id == "*"
      end
      config_keys = report.artifacts.filter_map do |artifact|
        artifact.key if artifact.relative_path == "config/ci.rb"
      end
      claimed_config_keys = claimed_keys & config_keys
      refute_empty claimed_config_keys
      suite_keys = report.to_h.dig(:inventory, :suite_scoped, :items).map { |item| item.fetch(:key) }
      verified_empty_keys = report.to_h.dig(:inventory, :verified_empty, :items).map { |item| item.fetch(:key) }
      claimed_config_keys.each do |key|
        assert_includes suite_keys, key
        refute_includes verified_empty_keys, key
      end
      assert report.complete?
    ensure
      Minitest::Testmon::ExecutionContext.reset_boundaries!
      Object.send(:remove_const, :TestmonConfigCiTarget) if Object.const_defined?(:TestmonConfigCiTarget, false)
    end
  end

  class CountingResolver
    attr_reader :resolve_count

    def initialize(resolver)
      @resolver = resolver
      @resolve_count = 0
    end

    def resolve(path, **options)
      @resolve_count += 1
      @resolver.resolve(path, **options)
    end

    def root(name)
      @resolver.root(name)
    end
  end

  def ruby_snapshot(project)
    configuration = Minitest::Testmon::Configuration.new(cwd: project)
    configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
    Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
  end

  class RecordingSession
    attr_reader :observations, :diagnostics

    def initialize
      @observations = []
      @diagnostics = []
    end

    def record(observation)
      @observations << observation
    end

    def incomplete(reason)
      @diagnostics << reason.to_s
    end
  end
end
