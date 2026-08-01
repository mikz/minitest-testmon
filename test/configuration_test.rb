# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < TestmonTestCase
  def test_default_state_is_a_single_sqlite_database
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)

      assert_equal File.join(project, ".minitest-testmon.sqlite3"), configuration.database_path
      assert_equal 10, configuration.retained_reports
      refute_respond_to configuration, :report
      refute_respond_to configuration, :report_path
    end
  end

  def test_retained_reports_accepts_only_positive_integers
    configuration = Minitest::Testmon::Configuration.new

    configuration.retained_reports 25
    assert_equal 25, configuration.retained_reports
    assert_raises(Minitest::Testmon::ConfigurationError) { configuration.retained_reports 0 }
    assert_raises(Minitest::Testmon::ConfigurationError) { configuration.retained_reports "many" }
    assert_raises(Minitest::Testmon::ConfigurationError) { configuration.retained_reports false }
    assert_raises(Minitest::Testmon::ConfigurationError) { configuration.retained_reports nil }
  end

  def test_versioned_snapshot_is_deterministic_and_immutable
    with_project do |project|
      first = Minitest::Testmon::Configuration.new(cwd: project)
      first.version 1
      first.ruby_files "lib/**/*.rb"
      first.fileset :features, include: ["features/**/*.feature"], mode: :paths
      signature = first.snapshot.signature

      second = Minitest::Testmon::Configuration.new(cwd: project)
      second.fileset :features, include: ["features/**/*.feature"], mode: :paths
      second.ruby_files "lib/**/*.rb"

      assert_equal signature, second.snapshot.signature
      assert_raises(Minitest::Testmon::ConfigurationError) { first.ruby_files "app/**/*.rb" }
    end
  end

  def test_unknown_version_is_rejected
    configuration = Minitest::Testmon::Configuration.new
    assert_raises(Minitest::Testmon::ConfigurationError) { configuration.version 2 }
  end

  def test_provider_dsl_is_frozen_and_publicly_introspectable
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      definition = configuration.provider :documents, version: 3 do
        inventory :templates, root: :project, include: "templates/**/*.erb"
        facet :content, inventory: :templates, digest: :content, granularity: :file
        facet :membership, inventory: :templates, digest: :paths, granularity: :set
        observe_tracepoint :render, target: [Kernel, :require], event: :call,
          path: ->(trace) { trace.local(:path) }
        observe_notification :render, "render.document",
          path: ->(notification) { notification.payload["identifier"] }
        claim :render, to: %i[templates content], path: :path
        claim :render, to: %i[templates membership]
        ignore :render, reason: "an inline template has no file", predicate: ->(observation) { observation.path.nil? }
      end
      configuration.snapshot

      assert_equal "documents@3", definition.id
      assert_equal :documents, definition.name
      assert_equal 3, definition.version
      assert_equal %i[content membership], definition.facets.map(&:name)
      assert_equal %i[notification tracepoint], definition.observers.map(&:type).sort
      assert_same definition, configuration.providers.fetch(0)
      assert configuration.providers.frozen?
      assert definition.inventories.frozen?
      assert definition.facets.frozen?
      assert definition.claims.frozen?
      assert definition.observers.frozen?
      assert_raises(FrozenError) { definition.inventories << :late }
    end
  end

  def test_provider_rejects_unknown_facets_invalid_combinations_and_non_define_implementations
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      error = assert_raises(Minitest::Testmon::ConfigurationError) do
        configuration.provider :bad_digest, version: 1 do
          inventory :files, root: :project, include: "**/*"
          facet :files, inventory: :files, digest: :existence, granularity: :set
        end
      end
      assert_match(/content\/file/, error.message)

      assert_raises(Minitest::Testmon::ConfigurationError) do
        configuration.provider(:bad_implementation, Object.new, version: 1)
      end

      assert_raises(Minitest::Testmon::ConfigurationError) do
        configuration.provider :missing_inventory, version: 1 do
          facet :files, inventory: :absent, digest: :paths, granularity: :set
        end
      end
    end
  end

  def test_implementation_can_only_declare_through_define
    with_project do |project|
      implementation = Class.new do
        def define(builder)
          builder.inventory :contracts, root: :project, include: "contracts/**/*.json"
          builder.facet :contracts, inventory: :contracts, digest: :contents, granularity: :set, scope: :suite
        end
      end.new
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      definition = configuration.provider(:contracts, implementation, version: 2)

      assert_equal "contracts@2", definition.id
      assert_equal :contents, definition.facets.fetch(0).digest
      assert_equal :suite, definition.facets.fetch(0).scope
    end
  end

  def test_fileset_sugar_compiles_to_an_ordinary_provider
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.fileset :templates, include: "templates/**/*.txt", mode: :contents

      provider = configuration.providers.fetch(0)
      assert_equal "fileset.templates@1", provider.id
      contents = provider.facets.find { |facet| facet.digest == :contents }
      assert_equal :set, contents.granularity
      membership = provider.facets.find { |facet| facet.digest == :paths }
      assert_equal :suite, membership.scope
      assert_equal :suite, contents.scope
      error = assert_raises(Minitest::Testmon::ConfigurationError) do
        Minitest::Testmon::Configuration.new(cwd: project).fileset(
          :unsafe,
          include: "templates/**/*.txt",
          scope: :test
        )
      end
      assert_match(/always suite-scoped/, error.message)
    end
  end

  def test_every_inventory_gets_exactly_one_suite_membership_by_default
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      definition = configuration.provider :documents, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :content, inventory: :documents, digest: :content, granularity: :file
      end

      memberships = definition.facets.select { |facet| facet.digest == :paths && facet.granularity == :set }
      assert_equal 1, memberships.length
      assert_equal :documents, memberships.first.inventory
      assert_equal :suite, memberships.first.scope
    end
  end

  def test_membership_remains_suite_scoped_even_with_a_static_claim
    with_project do |project|
      unobserved = Minitest::Testmon::Configuration.new(cwd: project).provider :unobserved, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :membership, inventory: :documents, digest: :paths, granularity: :set, scope: :test
      end
      assert_equal :suite, unobserved.facets.find { |facet| facet.digest == :paths }.scope

      observed = Minitest::Testmon::Configuration.new(cwd: project).provider :observed, version: 1 do
        inventory :documents, root: :project, include: "documents/**/*.txt"
        facet :membership, inventory: :documents, digest: :paths, granularity: :set, scope: :test
        claim :document_lookup, to: %i[documents membership]
      end
      assert_equal :suite, observed.facets.find { |facet| facet.digest == :paths }.scope
    end
  end

  def test_multiple_memberships_for_one_inventory_are_rejected
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      assert_raises(Minitest::Testmon::ConfigurationError) do
        configuration.provider :documents, version: 1 do
          inventory :documents, root: :project, include: "documents/**/*.txt"
          facet :membership, inventory: :documents, digest: :paths, granularity: :set
          facet :also_membership, inventory: :documents, digest: :paths, granularity: :set
        end
      end
    end
  end

  def test_configuration_source_content_enters_signature_without_its_path
    with_project do |project|
      first_path = write_file(File.join(project, "one.rb"), "VALUE = 1\n")
      second_path = write_file(File.join(project, "two.rb"), "VALUE = 1\n")
      first = Minitest::Testmon::Configuration.new(cwd: project)
      second = Minitest::Testmon::Configuration.new(cwd: project)
      first.record_config_source(first_path)
      second.record_config_source(second_path)
      assert_equal first.snapshot.signature, second.snapshot.signature

      write_file(second_path, "VALUE = 2\n")
      changed = Minitest::Testmon::Configuration.new(cwd: project)
      changed.record_config_source(second_path)
      refute_equal first.signature, changed.snapshot.signature
    end
  end

  def test_runtime_algorithm_versions_enter_the_configuration_signature
    with_project do |project|
      baseline = Minitest::Testmon::Configuration.new(cwd: project).signature
      engine = Minitest::Testmon::Engine.signature

      assert_equal Minitest::Testmon::VERSION, engine.fetch(:testmon_version)
      assert_equal Minitest::Testmon::FINGERPRINT_ALGORITHM_VERSION, engine.fetch(:fingerprint_algorithm)
      assert_equal Minitest::Testmon::SELECTION_ALGORITHM_VERSION, engine.fetch(:selection_algorithm)

      replacements = {
        VERSION: "#{Minitest::Testmon::VERSION}.changed",
        FINGERPRINT_ALGORITHM_VERSION: Minitest::Testmon::FINGERPRINT_ALGORITHM_VERSION + 1,
        SELECTION_ALGORITHM_VERSION: Minitest::Testmon::SELECTION_ALGORITHM_VERSION + 1
      }
      replacements.each do |name, value|
        with_testmon_constant(name, value) do
          refute_equal baseline, Minitest::Testmon::Configuration.new(cwd: project).signature
        end
      end
    end
  end

  private

  def with_testmon_constant(name, value)
    original = Minitest::Testmon.const_get(name, false)
    Minitest::Testmon.send(:remove_const, name)
    Minitest::Testmon.const_set(name, value)
    yield
  ensure
    Minitest::Testmon.send(:remove_const, name) if Minitest::Testmon.const_defined?(name, false)
    Minitest::Testmon.const_set(name, original)
  end
end
