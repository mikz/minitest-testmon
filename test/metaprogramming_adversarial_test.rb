# frozen_string_literal: true

require_relative "test_helper"

class MetaprogrammingAdversarialTest < TestmonTestCase
  TEST_ID = "MetaprogrammingTest#test_generated_behavior"

  def test_preloaded_define_method_is_attributed_to_its_source
    with_project do |project|
      source = write_file(File.join(project, "lib/define_method_target.rb"), <<~RUBY)
        class TestmonDefineMethodTarget
          define_method(:generated_value) { :defined }
        end
      RUBY
      load source

      report = observe(project) { TestmonDefineMethodTarget.new.generated_value }

      assert_test_dependency report, "lib/define_method_target.rb"
    ensure
      remove_constant(:TestmonDefineMethodTarget)
    end
  end

  def test_preloaded_class_eval_block_is_attributed_to_its_source
    with_project do |project|
      source = write_file(File.join(project, "lib/block_eval_target.rb"), <<~RUBY)
        class TestmonBlockEvalTarget
          class_eval do
            def generated_value = :block_eval
          end
        end
      RUBY
      load source

      report = observe(project) { TestmonBlockEvalTarget.new.generated_value }

      assert_test_dependency report, "lib/block_eval_target.rb"
    ensure
      remove_constant(:TestmonBlockEvalTarget)
    end
  end

  def test_string_eval_is_attributed_to_the_project_generator
    with_project do |project|
      source = write_file(File.join(project, "lib/string_eval_target.rb"), <<~RUBY)
        class TestmonStringEvalTarget
          def self.install
            class_eval("def generated_value = :string_eval")
          end
        end
      RUBY
      load source

      report = observe(project) do
        TestmonStringEvalTarget.install
        TestmonStringEvalTarget.new.generated_value
      end

      assert_test_dependency report, "lib/string_eval_target.rb"
    ensure
      remove_constant(:TestmonStringEvalTarget)
    end
  end

  def test_method_missing_is_attributed_to_its_ruby_implementation
    with_project do |project|
      source = write_file(File.join(project, "lib/method_missing_target.rb"), <<~RUBY)
        class TestmonMethodMissingTarget
          def method_missing(name, *)
            return :missing if name == :generated_value
            super
          end

          def respond_to_missing?(name, include_private = false)
            name == :generated_value || super
          end
        end
      RUBY
      load source

      report = observe(project) { TestmonMethodMissingTarget.new.generated_value }

      assert_test_dependency report, "lib/method_missing_target.rb"
    ensure
      remove_constant(:TestmonMethodMissingTarget)
    end
  end

  def test_native_attr_accessor_declaring_source_is_a_shared_dependency
    with_project do |project|
      declaration = write_file(File.join(project, "lib/accessor_target.rb"), <<~RUBY)
        class TestmonAccessorTarget
          attr_accessor :generated_value
        end
      RUBY
      load declaration
      target = TestmonAccessorTarget.new

      report = observe(project) do
        target.generated_value = :accessor
        target.generated_value
      end

      artifact = report.artifacts.find { |item| item.relative_path == "lib/accessor_target.rb" && item.facet == "ruby_source" }
      refute_nil artifact
      assert artifact.suite?
      assert report.dependencies.any? { |dependency| dependency.test_id == "*" && dependency.artifact_key == artifact.key }
      assert report.complete?, report.diagnostics.inspect
      shared_source = report.observations.any? do |observation|
        observation.operation == :native_source_shared && observation.explicit_suite_evidence? && observation.path == File.realpath(declaration)
      end
      assert shared_source
      refute report.observations.any? { |observation| observation.operation == :native_method_call }
    ensure
      remove_constant(:TestmonAccessorTarget)
    end
  end

  def test_eval_from_an_opaque_file_read_fails_closed
    with_project do |project|
      generated = write_file(File.join(project, "generated.rb"), "GENERATED_TESTMON_VALUE = :opaque\n")
      generator = write_file(File.join(project, "lib/opaque_eval_target.rb"), <<~RUBY)
        module TestmonOpaqueEvalTarget
          def self.call(path)
            eval(File.read(path))
          end
        end
      RUBY
      load generator

      report = observe(project, observe_files: true) { TestmonOpaqueEvalTarget.call(generated) }

      refute report.complete?
      assert report.observations.any? { |observation| observation.reason == :opaque_c_call }
    ensure
      remove_constant(:TestmonOpaqueEvalTarget)
      remove_constant(:GENERATED_TESTMON_VALUE)
    end
  end

  private

  def observe(project, observe_files: false)
    configuration = Minitest::Testmon::Configuration.new(cwd: project)
    configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
    snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
    session = snapshot.observe
    observer = Minitest::Testmon::CoreObserver.new(
      session,
      resolver: snapshot.context.resolver,
      allowed_roots: snapshot.ruby_inventory_roots,
      ruby_paths: snapshot.ruby_inventory_paths,
      test_only: true,
      observe_files: observe_files,
      boundary_tracker: Minitest::Testmon::ExecutionContext
    ).start
    session.attach_observer(observer)
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@snapshot, snapshot)
    runtime.instance_variable_set(:@session, session)
    runtime.instance_variable_set(:@suite_input_ids, [])
    runtime.send(:promote_native_sources, observer.native_source_locations)

    Minitest::Testmon::ExecutionContext.with_test(TEST_ID) { yield }
    session.executed(TEST_ID)
    session.selected!([TEST_ID])
    session.finalize
  ensure
    observer&.close
    Minitest::Testmon::ExecutionContext.clear
    Minitest::Testmon::ExecutionContext.reset_boundaries!
  end

  def assert_test_dependency(report, relative_path)
    keys = report.artifacts.filter_map do |artifact|
      artifact.key if artifact.relative_path == relative_path && artifact.facet == "ruby_source"
    end
    refute_empty keys, "missing Ruby source artifact for #{relative_path}"
    dependency_found = report.dependencies.any? do |dependency|
      dependency.test_id == TEST_ID && keys.include?(dependency.artifact_key)
    end
    assert dependency_found, {
      artifacts: report.artifacts.select { |artifact| artifact.relative_path == relative_path }.map(&:to_h),
      dependencies: report.dependencies.select { |dependency| dependency.test_id == TEST_ID }.map(&:to_h)
    }.inspect
    assert report.complete?, report.diagnostics.inspect
  end

  def remove_constant(name)
    Object.send(:remove_const, name) if Object.const_defined?(name, false)
  end
end
