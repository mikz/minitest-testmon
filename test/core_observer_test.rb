# frozen_string_literal: true

require_relative "test_helper"

class CoreObserverTest < TestmonTestCase
  def test_failed_target_does_not_disable_subsequent_valid_target_events
    with_project do |project|
      invalid_path = write_file(File.join(project, "invalid.rb"), "module TestmonInvalidTarget; end\n")
      invalid = nil
      RubyVM::InstructionSequence.compile_file(invalid_path).each_child { |child| invalid = child }
      valid_path = write_file(File.join(project, "valid.rb"), "proc { 42 }\n")
      block = RubyVM::InstructionSequence.compile_file(valid_path).eval
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(session,
        resolver: Minitest::Testmon::PathResolver.new(project: project), observe_files: false).start
      observer.send(:install_target, invalid)
      observer.send(:install_target, RubyVM::InstructionSequence.of(block))
      Minitest::Testmon::ExecutionContext.with_test("TargetTest#test_valid") { assert_equal 42, block.call }
      assert session.observations.any? { |item| item.kind == :provider_error && item.reason == :provider_incomplete }
      assert session.observations.any? { |item| item.kind == :coverage_lines && item.path == File.realpath(valid_path) }
    ensure
      observer&.close
    end
  end

  def test_loaded_target_reuses_policy_locator_across_executed_lines
    with_project do |project|
      path = write_file(File.join(project, "loop.rb"), "proc { total = 0; 20.times { total += 1 }; total }\n")
      block = RubyVM::InstructionSequence.compile_file(path).eval
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      policy = Minitest::Testmon::RubyPathPolicy.new(configuration)
      original = policy.method(:locator)
      calls = 0
      policy.define_singleton_method(:locator) do |source|
        calls += 1 if source == path
        original.call(source)
      end
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        ruby_paths: [path], ruby_path_policy: policy, observe_files: false).start
      calls = 0
      Minitest::Testmon::ExecutionContext.with_test("ProbeTest#test_loop") do
        10.times { assert_equal 20, block.call }
      end
      assert_equal 0, calls
      assert_equal [File.realpath(path)], session.observations.select { |item| item.kind == :coverage_lines }.map(&:path).uniq
    ensure
      observer&.close
    end
  end

  def test_disabled_file_observation_exposes_shared_accessor_sources_without_native_callbacks
    with_project do |project|
      data = write_file(File.join(project, "data.txt"), "payload")
      attributes = write_file(File.join(project, "attributes.rb"), <<~RUBY)
        class TestmonFileGateAttributes
          attr_reader :value, :read
        end
      RUBY
      reader = write_file(File.join(project, "reader.rb"), <<~RUBY)
        module TestmonFileGateReader
          def self.call
            File.read(#{data.dump})
          end
        end
      RUBY
      load attributes
      load reader
      [false, true].each do |observe_files|
        session = RecordingSession.new
        observer = Minitest::Testmon::CoreObserver.new(session,
          resolver: Minitest::Testmon::PathResolver.new(project: project),
          ruby_paths: [attributes, reader], observe_files:).start
        object = TestmonFileGateAttributes.new
        Minitest::Testmon::ExecutionContext.with_test("FileGateTest#value") { object.value }
        Minitest::Testmon::ExecutionContext.with_test("FileGateTest#read") { object.read }
        Minitest::Testmon::ExecutionContext.with_test("FileGateTest#file") do
          assert_equal "payload", TestmonFileGateReader.call
        end
        generic = session.observations.select { |observation| observation.kind == :file_read }
        assert_equal observe_files, generic.any? { |observation| observation.reason == :opaque_c_call }
        assert_empty generic unless observe_files
        native = session.observations.select { |observation| observation.operation == :native_method_call }
        assert_empty native
        assert_equal [File.realpath(attributes)], observer.native_source_locations.keys
        assert_nil observer.instance_variable_get(:@native_trace)
      ensure
        observer&.close
      end
    ensure
      Object.send(:remove_const, :TestmonFileGateReader) if Object.const_defined?(:TestmonFileGateReader, false)
      Object.send(:remove_const, :TestmonFileGateAttributes) if Object.const_defined?(:TestmonFileGateAttributes, false)
    end
  end

  def test_native_event_identity_does_not_dispatch_to_the_receiver
    receiver = Object.new
    receiver.define_singleton_method(:equal?) { |*| raise "receiver identity dispatched" }
    event = Struct.new(:self, :method_id, :defined_class).new(receiver, :unknown, Object)
    observer = Minitest::Testmon::CoreObserver.allocate
    observer.instance_variable_set(:@native_project_methods, {})

    observer.send(:observe_c_call, event)
  end

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

  def test_project_execution_without_a_propagated_token_during_a_test_is_ambiguous
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

      Minitest::Testmon::ThreadContextPropagation.install!
      Minitest::Testmon::ExecutionContext.set("ObserverTest#test_unowned_worker", thread_sources: {}.freeze)
      Thread.new { load script }.join
      Minitest::Testmon::ExecutionContext.clear
      observer.close

      ambiguous = session.observations.find { |item| item.operation == :unattributed_thread }
      refute_nil ambiguous
      assert_equal :ambiguous_context, ambiguous.reason
      assert_equal :suite, ambiguous.scope
      assert_equal ["ambiguous_context"], session.diagnostics
    ensure
      Minitest::Testmon::ExecutionContext.clear
      observer&.close
    end
  end

  def test_constant_read_maps_back_to_the_declaring_ruby_file
    with_project do |project|
      declaration = write_file(File.join(project, "declared.rb"), "TESTMON_DECLARED_VALUE = 7\n")
      reader = write_file(File.join(project, "reader.rb"), "raise 'unexpected constant value' unless TESTMON_DECLARED_VALUE == 7\n")
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

  def test_constant_plans_reuse_parsing_but_resolve_redefinitions_and_aliases_live
    with_project do |project|
      first = write_file(File.join(project, "first.rb"), "module TESTMON_PLAN_OWNER; VALUE = 7; end\nTESTMON_PLAN_ALIAS = TESTMON_PLAN_OWNER\n")
      second = write_file(File.join(project, "second.rb"), "TESTMON_PLAN_OWNER.const_set(:VALUE, 8)\n")
      third = write_file(File.join(project, "third.rb"), "module TESTMON_PLAN_OTHER; VALUE = 9; end\nTESTMON_PLAN_ALIAS = TESTMON_PLAN_OTHER\n")
      reader = write_file(File.join(project, "reader.rb"), "TESTMON_PLAN_ALIAS::VALUE\n")
      load first
      callable = -> {
        load reader
        TESTMON_PLAN_ALIAS::VALUE
      }
      session = RecordingSession.new
      resolver = Minitest::Testmon::PathResolver.new(project: project)
      observer = Minitest::Testmon::CoreObserver.new(session, resolver: resolver, observe_files: false).start
      locator = resolver.resolve(reader)
      lines = observer.send(:target_constant_lines, locator)
      assert_same lines, observer.send(:target_constant_lines, locator)
      assert lines.frozen?
      assert_equal({1 => true}, lines)
      Minitest::Testmon::ExecutionContext.with_test("Plans#first") { assert_equal 7, callable.call }
      TESTMON_PLAN_OWNER.send(:remove_const, :VALUE)
      Minitest::Testmon::ExecutionContext.with_test("Plans#missing") { assert_raises(NameError) { callable.call } }
      load second
      Minitest::Testmon::ExecutionContext.with_test("Plans#second") { assert_equal 8, callable.call }
      Object.send(:remove_const, :TESTMON_PLAN_ALIAS)
      load third
      Minitest::Testmon::ExecutionContext.with_test("Plans#third") { assert_equal 9, callable.call }
      reads = session.observations.select { |item| item.operation == :constant_read }
      %w[first second third].zip([first, second, third]).each do |name, path|
        assert_includes reads.select { |item| item.test_id == "Plans##{name}" }.map(&:path), File.realpath(path)
      end
      refute reads.any? { |item| item.test_id == "Plans#missing" }
    ensure
      observer&.close
      %i[TESTMON_PLAN_ALIAS TESTMON_PLAN_OWNER TESTMON_PLAN_OTHER].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
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
      target = RubyVM::InstructionSequence.of(TestmonPreloadedTarget.method(:call))

      assert observer.instance_variable_get(:@target_traces).key?(target),
        "target trace did not retain its instruction sequence"

      Minitest::Testmon::ExecutionContext.with_test("TargetTest#test_call") do
        TestmonPreloadedTarget.call
      end
      observer.close

      observation = session.observations.find do |item|
        item.kind == :coverage_lines && item.path == File.realpath(script)
      end
      refute_nil observation
      assert_equal File.realpath(script), observation.path
    ensure
      Object.send(:remove_const, :TestmonPreloadedTarget) if Object.const_defined?(:TestmonPreloadedTarget, false)
    end
  end

  def test_preloaded_project_method_scan_does_not_dispatch_introspection_to_the_owner
    with_project do |project|
      script = write_file(File.join(project, "introspection_trap.rb"), <<~RUBY)
        module TestmonIntrospectionTrap
          def call
            :called
          end

          class << self
            def public_instance_methods(*) = raise "owner introspection dispatched"
            def protected_instance_methods(*) = raise "owner introspection dispatched"
            def private_instance_methods(*) = raise "owner introspection dispatched"
            def instance_method(*) = raise "owner introspection dispatched"
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
        Object.new.extend(TestmonIntrospectionTrap).call
      end
      observer.close

      observation = session.observations.find do |item|
        item.kind == :coverage_lines && item.path == File.realpath(script)
      end
      refute_nil observation
      assert_equal File.realpath(script), observation.path
    ensure
      Object.send(:remove_const, :TestmonIntrospectionTrap) if Object.const_defined?(:TestmonIntrospectionTrap, false)
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

  def test_early_observation_ignores_excluded_ruby_and_its_opaque_file_reads
    with_project do |project|
      data = write_file(File.join(project, "data.txt"), "value")
      application = write_file(File.join(project, "app/reader.rb"), "File.read(#{data.dump})\n")
      dependency = write_file(
        File.join(project, "vendor/bundle/ruby/4.0.0/gems/example/lib/example.rb"),
        "File.read(#{data.dump})\n"
      )
      dependency_link = File.join(project, "lib/example.rb")
      FileUtils.mkdir_p(File.dirname(dependency_link))
      File.symlink(dependency, dependency_link)
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      resolver = Minitest::Testmon::PathResolver.new(project: project)
      session = RecordingSession.new
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: resolver,
        ruby_path_policy: Minitest::Testmon::RubyPathPolicy.new(configuration)
      ).start

      load dependency_link
      load application
      observer.close

      dependency_paths = [File.realpath(dependency), resolver.resolve(dependency).key]
      dependency_observed = session.observations.any? do |observation|
        dependency_paths.include?(observation.path) || dependency_paths.include?(observation.callsite&.fetch(:path))
      end
      refute dependency_observed, session.observations.map(&:report_item)
      application_paths = [File.realpath(application), resolver.resolve(application).key]
      application_observed = session.observations.any? do |observation|
        application_paths.include?(observation.path) || application_paths.include?(observation.callsite&.fetch(:path))
      end
      assert application_observed
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
        artifact.relative_path == "lib/unhookable.rb" && artifact.facet == "ruby_source"
      end

      refute_empty source_artifacts
      assert source_artifacts.all? { |artifact| artifact.scope == :suite }
      assert source_artifacts.all? { |artifact| artifact.reason.nil? }
      assert_equal [File.realpath(script)], snapshot.ruby_unhookable_paths
      capability = snapshot.context.capabilities.fetch(0)
      assert_equal "project:lib/unhookable.rb", capability.fetch(:source)
      assert_equal %w[line call b_call], capability.fetch(:requested_events)
      assert_equal(
        [[1, "class"], [2, "end"]],
        capability.fetch(:unhookable).fetch(0).fetch(:trace_points)
      )

      session = snapshot.observe
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

  def test_sealed_ruby_inventory_attributes_a_joined_child_to_its_test
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

      session = snapshot.observe
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

      Minitest::Testmon::ThreadContextPropagation.install!
      test_id = "ConfigTest#test_background"
      Minitest::Testmon::ExecutionContext.set(test_id)
      Minitest::Testmon::ExecutionContext.begin_boundary
      Thread.new { TestmonConfigCiTarget.call }.join
      Minitest::Testmon::ExecutionContext.clear
      Minitest::Testmon::ExecutionContext.end_boundary
      report = session.finalize

      observation = report.observations.find do |item|
        item.kind == :coverage_lines && item.path == File.realpath(script)
      end
      refute_nil observation
      assert_equal test_id, observation.test_id
      claimed_keys = report.dependencies.filter_map do |dependency|
        dependency.artifact_key if dependency.test_id == test_id
      end
      config_keys = report.artifacts.filter_map do |artifact|
        artifact.key if artifact.relative_path == "config/ci.rb"
      end
      claimed_config_keys = claimed_keys & config_keys
      refute_empty claimed_config_keys
      assert report.complete?
      assert_empty report.diagnostics
    ensure
      Minitest::Testmon::ExecutionContext.reset_boundaries!
      Object.send(:remove_const, :TestmonConfigCiTarget) if Object.const_defined?(:TestmonConfigCiTarget, false)
    end
  end

  def test_preexisting_thread_execution_during_a_boundary_fails_closed
    with_project do |project|
      script = write_file(File.join(project, "preexisting.rb"), <<~RUBY)
        module TestmonPreexistingTarget
          def self.call = :called
        end
      RUBY
      load script
      snapshot = ruby_snapshot(project)
      session = snapshot.observe
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
      ready = Queue.new
      release = Queue.new
      worker = Thread.new do
        ready << true
        release.pop
        TestmonPreexistingTarget.call
      end
      ready.pop

      test_id = "ConfigTest#test_preexisting"
      Minitest::Testmon::ExecutionContext.set(test_id)
      Minitest::Testmon::ExecutionContext.begin_boundary
      release << true
      worker.join
      Minitest::Testmon::ExecutionContext.clear
      Minitest::Testmon::ExecutionContext.end_boundary
      report = session.finalize

      refute report.complete?
      assert_includes report.diagnostics, "ambiguous_context"
      assert report.observations.any? { |item| item.reason == :ambiguous_context }
    ensure
      Minitest::Testmon::ExecutionContext.reset_boundaries!
      Minitest::Testmon::ExecutionContext.clear
      Object.send(:remove_const, :TestmonPreexistingTarget) if Object.const_defined?(:TestmonPreexistingTarget, false)
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
