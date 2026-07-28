# frozen_string_literal: true

require_relative "test_helper"

class ProviderObserverTest < TestmonTestCase
  class Loader
    def load_document(filename)
      File.binread(filename)
    end
  end

  module InspectShadowLoader
    class << self
      def inspect(value, max_depth = 2)
        [value, max_depth]
      end

      def load_document(filename)
        File.binread(filename)
      end
    end
  end

  class DeclaredFixtureCase
    def self.fixture_table_names
      [:all]
    end

    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  class EmptyFixtureCase < DeclaredFixtureCase
    def self.fixture_table_names
      []
    end
  end

  class PlainCase
    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  class BuiltinFixtureProvider
    attr_reader :wrapper_methods

    def define(builder)
      builder.inventory :fixtures, root: :project, include: "fixtures/**/*.yml"
      builder.facet :content, inventory: :fixtures, digest: :content, granularity: :file
      builder.facet :membership, inventory: :fixtures, digest: :paths, granularity: :set
      builder.__send__(
        :__observe_builtin_test_start,
        :declared_fixtures,
        details: ->(test) {
          @wrapper_methods = test.class.instance_methods(false).sort
          names = Array(test.class_value(:fixture_table_names))
          {"names" => names} unless names.empty?
        }
      )
      builder.claim :declared_fixtures,
        to: %i[fixtures content],
        using: ->(_observation, facet) { facet.artifact_keys }
      builder.claim :declared_fixtures,
        to: %i[fixtures membership],
        using: ->(_observation, facet) { facet.artifact_keys }
    end
  end

  def test_tracepoint_observer_exposes_only_the_read_only_wrapper_and_claims_declared_files
    with_project do |project|
      path = write_file(File.join(project, "documents", "invoice.txt"), "total")
      wrapper_methods = nil
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :documents, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :content, inventory: :documents, digest: :content, granularity: :file
        observe_tracepoint :document_read,
          target: [ProviderObserverTest::Loader, :load_document],
          path: ->(trace) {
            wrapper_methods = trace.class.instance_methods(false).sort
            trace.local(:filename)
          },
          details: ->(trace) { {"method" => trace.method_id.to_s, "line" => trace.lineno} }
        claim :document_read, to: %i[documents content], path: :path
      end
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe

      Minitest::Testmon::ExecutionContext.with_test("DocumentTest#test_invoice") do
        Loader.new.load_document(path)
      end
      report = session.finalize

      assert report.complete?
      assert_equal %i[event lineno local method_id path], wrapper_methods
      assert_equal 1, report.dependencies.count { |item| item.test_id == "DocumentTest#test_invoice" }
      assert_equal :"documents@1", report.dependencies.fetch(0).provider
    end
  end

  def test_tracepoint_owner_does_not_dispatch_inspect_to_the_observed_module
    with_project do |project|
      path = write_file(File.join(project, "documents", "invoice.txt"), "total")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :documents, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :content, inventory: :documents, digest: :content, granularity: :file
        observe_tracepoint :document_read,
          target: [ProviderObserverTest::InspectShadowLoader, :load_document],
          path: ->(trace) { trace.local(:filename) }
        claim :document_read, to: %i[documents content], path: :path
      end
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe

      result = Minitest::Testmon::ExecutionContext.with_test("DocumentTest#test_invoice") do
        InspectShadowLoader.load_document(path)
      end
      report = session.finalize

      assert_equal "total", result
      assert report.complete?
      assert_equal "#<Class:ProviderObserverTest::InspectShadowLoader>",
        report.observations.fetch(0).callsite.fetch(:owner)
      assert_equal 1, report.dependencies.count { |item| item.test_id == "DocumentTest#test_invoice" }
    end
  end

  def test_tracepoint_failure_for_an_inspect_shadowing_owner_does_not_escape_application_code
    with_project do |project|
      path = write_file(File.join(project, "documents", "invoice.txt"), "total")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :documents, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :content, inventory: :documents, digest: :content, granularity: :file
        observe_tracepoint :document_read,
          target: [ProviderObserverTest::InspectShadowLoader, :load_document],
          path: ->(trace) { trace.local(:filename) },
          details: ->(_trace) { {"unsupported" => Object.new} }
        claim :document_read, to: %i[documents content], path: :path
      end
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe

      result = Minitest::Testmon::ExecutionContext.with_test("DocumentTest#test_invoice") do
        InspectShadowLoader.load_document(path)
      end
      report = session.finalize

      assert_equal "total", result
      refute report.complete?
      assert_includes report.diagnostics, "noncanonical_observation"
      observation = report.observations.fetch(0)
      assert_equal :noncanonical_observation, observation.reason
      assert_equal "#<Class:ProviderObserverTest::InspectShadowLoader>",
        observation.callsite.fetch(:owner)
    end
  end

  def test_missing_tracepoint_target_forces_full_before_filtering
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :documents, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :content, inventory: :documents, digest: :content, granularity: :file
        observe_tracepoint :document_read,
          target: [ProviderObserverTest::Loader, :method_that_does_not_exist]
        claim :document_read, to: %i[documents content], path: :path
      end
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
      report = session.finalize

      refute session.startup_complete?
      refute report.complete?
      assert_includes report.diagnostics, "observer_unavailable"
      assert_equal :observer_unavailable, report.observations.fetch(0).reason
    end
  end

  def test_extractor_and_noncanonical_details_errors_never_escape_application_code
    with_project do |project|
      path = write_file(File.join(project, "documents", "invoice.txt"), "total")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :documents, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :content, inventory: :documents, digest: :content, granularity: :file
        observe_tracepoint :document_read,
          target: [ProviderObserverTest::Loader, :load_document],
          path: ->(trace) { trace.local(:filename) },
          details: ->(_trace) { {symbol_key: Object.new} }
        claim :document_read, to: %i[documents content], path: :path
      end
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe

      result = Minitest::Testmon::ExecutionContext.with_test("DocumentTest#test_invoice") do
        Loader.new.load_document(path)
      end
      report = session.finalize

      assert_equal "total", result
      refute report.complete?
      assert_includes report.diagnostics, "noncanonical_observation"
      assert_equal :noncanonical_observation, report.observations.fetch(0).reason
    end
  end

  def test_builtin_test_start_observer_is_internal_canonical_and_order_independent
    refute_includes Minitest::Testmon::ProviderDefinitionBuilder.public_instance_methods, :observe_test_start
    assert_includes Minitest::Testmon::ProviderDefinitionBuilder.private_instance_methods,
      :__observe_builtin_test_start

    inventories = [
      fixture_inventory_for(%w[test_alpha test_beta]),
      fixture_inventory_for(%w[test_beta test_alpha])
    ]

    assert_equal inventories.first, inventories.last
    claimed = inventories.first.fetch(:claimed).fetch(:items)
    assert_equal 3, claimed.length
    claimed.each do |item|
      assert_equal(
        [
          "ProviderObserverTest::DeclaredFixtureCase#test_alpha",
          "ProviderObserverTest::DeclaredFixtureCase#test_beta"
        ],
        item.fetch(:test_ids)
      )
    end
  end

  private

  def fixture_inventory_for(order)
    with_project do |project|
      write_file(File.join(project, "fixtures", "one.yml"), "one")
      write_file(File.join(project, "fixtures", "two.yml"), "two")
      implementation = BuiltinFixtureProvider.new
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :fixtures, implementation, version: 1
      definition = configuration.providers.fetch(0)
      assert definition.observers.frozen?
      assert_equal [:test_start], definition.observers.map(&:type)

      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
      order.each do |name|
        session.test_started(DeclaredFixtureCase.new(name))
      end
      session.test_started(EmptyFixtureCase.new("test_empty"))
      session.test_started(PlainCase.new("test_plain"))
      report = session.finalize

      assert report.complete?
      assert_equal %i[class_name class_value name test_id], implementation.wrapper_methods
      assert_equal 2, report.observations.count { |item| item.kind == :declared_fixtures }
      assert report.observations.all? { |item| item.details.frozen? }
      report.to_h.fetch(:inventory)
    end
  end
end
