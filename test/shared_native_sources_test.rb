# frozen_string_literal: true

require_relative "test_helper"

class SharedNativeSourcesTest < TestmonTestCase
  def test_source_loaded_through_alias_uses_the_configured_external_root_identity
    with_project do |project|
      with_project do |external|
        source = write_file(File.join(external, "attributes.rb"), "class SharedNativeExternalFixture; attr_reader :value; end\n")
        alias_path = File.join(project, "alias.rb")
        File.symlink(source, alias_path)
        load alias_path
        configuration = Minitest::Testmon::Configuration.new(cwd: project)
        configuration.root(:shared, external)
        configuration.ruby_files("**/*.rb", root: :shared)
        configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
        snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
        session = snapshot.observe
        observer = Minitest::Testmon::CoreObserver.new(session, resolver: snapshot.context.resolver,
          allowed_roots: snapshot.ruby_inventory_roots, ruby_paths: snapshot.ruby_inventory_paths, observe_files: false).start
        assert_equal [File.realpath(source)], observer.native_source_locations.keys
        runtime = promotion_runtime(snapshot, session)
        runtime.send(:promote_native_sources, observer.native_source_locations)
        promoted = runtime.send(:current_inputs).select { |input| input.root == "shared" && input.members.include?("identity:whole_file") }
        assert_equal 1, promoted.length
        assert promoted.first.suite?
        assert_includes snapshot.current_inputs.map(&:id), promoted.first.id
        assert_equal "attributes.rb", promoted.first.relative_path
      ensure
        observer&.close
        session&.finalize
        Object.send(:remove_const, :SharedNativeExternalFixture) if Object.const_defined?(:SharedNativeExternalFixture, false)
      end
    end
  end

  def test_missing_catalog_and_custom_provider_without_definition_fail_closed
    with_project do |project|
      source = write_file(File.join(project, "attributes.rb"), "class UnknownNativeFixture; end\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      original = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      [false, true].each do |custom|
        session = original.observe
        snapshot = original.dup
        if custom
          registration = Minitest::Testmon::Registration.new(name: :ruby, provider: Object.new, version: 1, options: {})
          snapshot.instance_variable_set(:@registrations, [registration])
        end
        location = custom ? source : File.join(project, "absent.rb")
        runtime = promotion_runtime(snapshot, session)
        runtime.send(:promote_native_sources, {File.realpath(project) + "/" + File.basename(location) => 1})
        refute session.startup_complete?
      ensure
        session&.finalize
      end
    end
  end

  def test_promotion_selects_old_cached_tests_and_is_retained_by_checkpoint_and_final_report
    with_project do |project|
      source = write_file(File.join(project, "attributes.rb"), "class SharedNativeSourceFixture; attr_reader :value; end\n")
      write_file(File.join(project, "ordinary.rb"), "class OrdinarySourceFixture; def value; 1; end; end\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      ids = %w[OneTest#one TwoTest#two]
      session = snapshot.observe(tests: {discovered: ids}, selected: ids)
      runtime = Minitest::Testmon::Runtime.allocate
      runtime.instance_variable_set(:@snapshot, snapshot)
      runtime.instance_variable_set(:@session, session)
      runtime.instance_variable_set(:@suite_input_ids, [])
      runtime.send(:promote_native_sources, {File.realpath(source) => 1})
      current = runtime.send(:current_inputs)
      native = current.find { |input| input.relative_path == "attributes.rb" && input.members.include?("identity:whole_file") }
      refute_nil native
      assert native.suite?
      ordinary = current.find { |input| input.relative_path == "ordinary.rb" && input.members.include?("identity:whole_file") }
      assert_equal snapshot.current_inputs.find { |input| input.id == ordinary.id }.scope, ordinary.scope
      refute ordinary.suite?
      required = runtime.instance_variable_get(:@suite_input_ids)
      assert_includes required, native.id
      old = ids.to_h do |id|
        [id, Minitest::Testmon::TestSnapshot.new(test_id: id,
          inputs: current.reject { |input| input.id == native.id }, recorded_at: "old", run_id: "old")]
      end
      selected = Minitest::Testmon::Selector.new.call(discovered: ids, current_inputs: current,
        snapshots: old, retries: {}, base_revision: nil, suite_input_ids: required)
      assert_equal ids, selected.selected
      assert selected.reasons_by_test.values.flatten.all? { |reason| reason.start_with?("suite_input_missing:") }

      # A focused run keeps the shared source even without an accessor call.
      session.retain_suite_input_ids!(required)
      assert session.checkpoint_report.complete?
      checkpoint_source = session.current_inputs.find { |input| input.id == native.id }
      assert checkpoint_source.suite?
      learned = ids.to_h do |id|
        [id, Minitest::Testmon::SnapshotBuilder.new.call(test_id: id, current_inputs: session.current_inputs,
          claimed_input_ids: [], test_definition_input: nil, recorded_at: "now", run_id: "partial")]
      end
      warm = Minitest::Testmon::Selector.new.call(discovered: ids, current_inputs: current,
        snapshots: learned, retries: {}, base_revision: nil, suite_input_ids: required)
      assert_empty warm.selected
      changed = current.map { |input| (input.id == native.id) ? input.with(fingerprint: Minitest::Testmon::Fingerprint.known("changed")) : input }
      assert_equal ids, Minitest::Testmon::Selector.new.call(discovered: ids, current_inputs: changed,
        snapshots: learned, retries: {}, base_revision: nil, suite_input_ids: required).selected

      store = Minitest::Testmon::Store.new(File.join(project, "tmp/checkpoint.sqlite3"))
      store.acquire_lease!(run_id: "partial")
      store.start_execution(run_id: "partial", selection: selected)
      store.checkpoint(run_id: "partial", base_revision: nil, snapshots: [learned.fetch(ids.first)])
      store.release_lease!
      persisted = store.snapshots_for(ids).fetch(ids.first)
      assert persisted.inputs.find { |input| input.id == native.id }.suite?
      assert_equal "abandoned", store.runs.first.fetch("state")
      assert session.finalize.complete?
      assert session.current_inputs.find { |input| input.id == native.id }.suite?
    ensure
      store&.close
      session&.finalize if session&.instance_variable_get(:@phase) == :observing
    end
  end

  private

  def promotion_runtime(snapshot, session)
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@snapshot, snapshot)
    runtime.instance_variable_set(:@session, session)
    runtime.instance_variable_set(:@suite_input_ids, [])
    runtime
  end
end
