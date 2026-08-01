# frozen_string_literal: true

require_relative "test_helper"

class RailsFixturesTest < TestmonTestCase
  TEST_ID = "RailsFixturesTest::DeclaredFixtureCase#test_widgets"
  WORKER_RUN_ID = "22222222-2222-4222-8222-222222222222"

  class DeclaredFixtureCase
    def self.fixture_table_names
      [:widgets]
    end

    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  def test_manual_fixture_load_filters_same_named_content_and_membership_by_canonical_root
    with_fixture_snapshot do |snapshot, fixture_set, project, project_fixtures, _shared_fixtures|
      serial = manual_report(snapshot, fixture_set, project_fixtures)
      worker = manual_worker_report(snapshot, fixture_set, project, project_fixtures)

      assert serial.complete?
      assert worker.complete?
      assert_equal serial.to_h.fetch(:inventory), worker.to_h.fetch(:inventory)
      assert_equal(
        ["project:fixtures", "project:fixtures/widgets.yml"],
        claimed_paths(serial, TEST_ID)
      )
      assert_equal(
        ["shared:fixtures/widgets.yml"],
        serial.to_h.dig(:inventory, :verified_empty, :items).map { |item| item.fetch(:path) }.sort
      )
      assert_equal(
        ["project:fixtures", "shared:fixtures"],
        serial.to_h.dig(:inventory, :suite_scoped, :items).map { |item| item.fetch(:path) }.sort
      )
    end
  end

  def test_declared_fixture_names_span_every_configured_fixture_root
    with_fixture_snapshot do |snapshot, _fixture_set, _project, _project_fixtures, _shared_fixtures|
      session = snapshot.observe
      session.test_started(DeclaredFixtureCase.new("test_widgets"))
      report = session.finalize

      assert report.complete?
      assert_equal(
        [
          "project:fixtures",
          "project:fixtures/widgets.yml",
          "shared:fixtures",
          "shared:fixtures/widgets.yml"
        ],
        claimed_paths(report, TEST_ID)
      )
    end
  end

  private

  def with_fixture_snapshot
    raise "ActiveRecord unexpectedly loaded in the gem unit suite" if Object.const_defined?(:ActiveRecord, false)
    raise "ActiveSupport unexpectedly loaded in the gem unit suite" if Object.const_defined?(:ActiveSupport, false)

    with_project do |project|
      Dir.mktmpdir("minitest-testmon-shared-fixtures") do |shared|
        project_fixtures = File.join(project, "fixtures")
        shared_fixtures = File.join(shared, "fixtures")
        write_file(File.join(project_fixtures, "widgets.yml"), "project")
        write_file(File.join(shared_fixtures, "widgets.yml"), "shared")
        fixture_set = install_fixture_framework([project_fixtures, shared_fixtures])
        configuration = Minitest::Testmon::Configuration.new(cwd: project)
        configuration.root(:shared, shared)
        implementation = Minitest::Testmon::Bundles::Rails81::FixturesDefinition.new(configuration)
        configuration.provider :"rails.fixtures", implementation, version: 1
        snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)

        yield snapshot, fixture_set, project, project_fixtures, shared_fixtures
      end
    ensure
      Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord, false)
      Object.send(:remove_const, :ActiveSupport) if Object.const_defined?(:ActiveSupport, false)
    end
  end

  def install_fixture_framework(roots)
    fixture_set = Class.new do
      def self.create_fixtures(fixtures_directories, fixture_set_names, class_names = {}, config = nil)
        [fixtures_directories, fixture_set_names, class_names, config]
      end
    end
    active_record = Module.new
    active_record.const_set(:FixtureSet, fixture_set)
    Object.const_set(:ActiveRecord, active_record)
    test_case = Class.new
    test_case.define_singleton_method(:fixture_paths) { roots }
    active_support = Module.new
    active_support.const_set(:TestCase, test_case)
    Object.const_set(:ActiveSupport, active_support)
    fixture_set
  end

  def manual_report(snapshot, fixture_set, directory)
    session = snapshot.observe
    Minitest::Testmon::ExecutionContext.with_test(TEST_ID) do
      fixture_set.create_fixtures([directory], [:widgets])
    end
    session.finalize
  end

  def manual_worker_report(snapshot, fixture_set, project, directory)
    spool = Minitest::Testmon::WorkerSpool.new(
      directory: File.join(project, "worker-spool"),
      run_id: WORKER_RUN_ID,
      worker_number: 0,
      context_signature: snapshot.signature,
      base_revision: 1
    )
    worker = snapshot.observe
    worker.attach_spool(spool)
    Minitest::Testmon::ExecutionContext.with_test(TEST_ID) do
      fixture_set.create_fixtures([directory], [:widgets])
    end
    assert worker.close_observers_for_worker!
    worker.seal_worker!
    assert spool.complete!
    merged = Minitest::Testmon::WorkerSpool.merge(
      directory: File.join(project, "worker-spool"),
      run_id: WORKER_RUN_ID,
      worker_count: 1,
      context_signature: snapshot.signature,
      base_revision: 1
    )
    assert merged.complete

    parent = snapshot.observe
    assert parent.close_observers_for_worker!
    merged.observations.each { |observation| parent.import_observation(observation) }
    parent.finalize
  end

  def claimed_paths(report, test_id)
    keys = report.dependencies.filter_map do |dependency|
      dependency.artifact_key if dependency.test_id == test_id
    end
    report.artifacts.filter_map { |artifact| artifact.path if keys.include?(artifact.key) }.uniq.sort
  end
end
