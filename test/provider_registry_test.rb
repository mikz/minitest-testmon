# frozen_string_literal: true

require_relative "test_helper"

class ProviderRegistryTest < TestmonTestCase
  def test_artifact_aggregation_preserves_canonical_representative_and_test_ownership
    base = Minitest::Testmon::Artifact.new(key: 'quoted"input', provider: :example,
      root: :project, relative_path: "žluťoučký.txt", facet: :content,
      fingerprint: Minitest::Testmon::Fingerprint.known("digest"), members: [],
      scope: :test, test_ids: ["Z#test"], reason: nil, identity: :content)
    variants = [base, base.with(test_ids: ['A#test"quoted']),
      base.with(members: ["z", "a"], test_ids: ["B#test"]),
      base.with(fingerprint: Minitest::Testmon::Fingerprint.unknown(:source_race), reason: :source_race)]
    session = Minitest::Testmon::ProviderSession.allocate
    [variants, variants + [base.with(scope: :suite, test_ids: [])]].each do |items|
      representative = items.min_by { |item| Minitest::Testmon::CanonicalJSON.generate(item.inventory_item) }
      scope = items.any?(&:suite?) ? :suite : :test
      ids = (scope == :suite) ? [] : items.flat_map(&:test_ids).compact.uniq.sort
      expected = representative.with(scope: scope, test_ids: ids)
      assert_equal [expected], session.send(:deduplicate_artifacts, items)
      assert_equal [expected], session.send(:deduplicate_artifacts, items.reverse)
    end
  end

  def test_pruned_exclusion_enumeration_matches_glob_with_symlinks_and_patterns
    with_project do |project|
      project = File.realpath(project)
      %w[test/keep.rb test/.hidden.rb test/drop.rb vendor/private.rb targets/linked.rb].each do |name|
        write_file(File.join(project, name), "value")
      end
      File.symlink("../targets", File.join(project, "test/link"))
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :files, version: 1 do
        inventory :files, root: :project,
          include: ["test/**/*", "test/link/*.rb"],
          exclude: ["vendor/**/*", "test/{drop,.hidden}.rb", "test/link/**/*", "test/../vendor/**/*"]
        facet :content, inventory: :files, digest: :content, granularity: :file
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      provider = snapshot.registrations.first.provider
      inventory = provider.definition.inventories.first
      included = inventory.include_patterns.flat_map { |pattern| Dir.glob(File.join(project, pattern), File::FNM_DOTMATCH) }.uniq
      excluded = inventory.exclude_patterns.flat_map { |pattern| Dir.glob(File.join(project, pattern), File::FNM_DOTMATCH) }
        .to_h { |path| [File.expand_path(path), true] }
      expected = included.reject { |path| excluded.key?(File.expand_path(path)) }
      assert_equal expected, provider.send(:inventory_paths, inventory)
      assert_equal File.join(project, "vendor/"), provider.send(:exclusion_directory_prefix, project, "vendor/**/*")
      assert_nil provider.send(:exclusion_directory_prefix, project, "test/../vendor/**/*")
    end
  end

  def test_snapshot_exposes_deterministic_inputs_with_context_and_exact_byte_ruby_digest
    with_project do |project|
      ruby_path = write_file(File.join(project, "lib", "account.rb"), "class Account; end\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)

      assert snapshot.current_inputs.frozen?
      assert_equal snapshot.current_inputs.sort_by { |input| input.id.to_s }, snapshot.current_inputs
      assert_equal snapshot.current_inputs, snapshot.current_inputs_by_id.values.sort_by { |input| input.id.to_s }
      context = snapshot.current_inputs.find { |input| input.key == "$context" }
      assert_equal :suite, context.scope
      ruby_input = snapshot.current_inputs.find do |input|
        input.relative_path == "lib/account.rb" && input.facet == "ruby_source"
      end
      assert_equal Digest::SHA256.file(ruby_path).hexdigest, ruby_input.fingerprint.digest
    end
  end

  def test_repeated_source_validation_detects_same_size_edits_and_membership_changes
    with_project do |project|
      path = write_file(File.join(project, "lib/account.rb"), "class Account; X = 1; end\n")
      original_time = File.mtime(path)
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      assert snapshot.source_stable?
      assert snapshot.source_stable?
      File.write(path, "class Account; X = 2; end\n")
      File.utime(original_time, original_time, path)
      refute snapshot.source_stable?
      File.write(path, "class Account; X = 1; end\n")
      assert snapshot.source_stable?
      write_file(File.join(project, "lib/new.rb"), "NEW = true\n")
      refute snapshot.source_stable?
    end
  end

  def test_checkpoints_and_final_report_claim_each_observation_once
    with_project do |project|
      path = write_file(File.join(project, "templates/invoice.txt"), "total")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :templates, version: 1 do
        inventory :templates, root: :project, include: "templates/**/*.txt"
        facet :content, inventory: :templates, digest: :content, granularity: :file
        claim :template_read, to: %i[templates content], path: :path
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      provider = snapshot.registrations.first.provider
      original_claim = provider.method(:claim)
      calls = 0
      provider.define_singleton_method(:claim) do |observation, claims|
        calls += 1
        original_claim.call(observation, claims)
      end
      session = snapshot.observe
      observation = Minitest::Testmon::Observation.build(kind: :template_read,
        provider: :templates, path: path, test_id: "InvoiceTest#test_total")
      3.times { session.record(observation) }
      assert session.checkpoint_report.complete?
      session.record(observation)
      session.import_observation(observation)
      assert session.checkpoint_report.complete?
      assert_equal 1, session.instance_variable_get(:@observations).length
      assert session.finalize.complete?
      assert_equal 1, calls
    end
  end

  def test_test_definition_is_an_ordinary_claimed_input
    with_project do |project|
      source = write_file(File.join(project, "test", "generated_definition_test.rb"), <<~RUBY)
        class GeneratedDefinitionTest < Minitest::Test
          def test_generated
            assert true
          end
        end
      RUBY
      load source
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      test_id = "GeneratedDefinitionTest#test_generated"
      definition = snapshot.test_definition_input(test_id)

      assert_equal "test/generated_definition_test.rb", definition.relative_path
      assert_equal Digest::SHA256.file(source).hexdigest, definition.fingerprint.digest

      session = snapshot.observe
      session.test_started(GeneratedDefinitionTest.new("test_generated"))
      session.finalize
      assert_includes session.claimed_input_ids(test_id), definition.id
      assert session.claimed_input_ids_by_test.frozen?
    ensure
      Object.send(:remove_const, :GeneratedDefinitionTest) if Object.const_defined?(:GeneratedDefinitionTest, false)
    end
  end

  def test_provider_finalization_disables_early_checkpoint_publication
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      finalized = false
      snapshot.registrations.first.provider.define_singleton_method(:finalize) { |_claims| finalized = true }
      session = snapshot.observe
      refute session.checkpoint_supported?
      refute finalized
      assert session.finalize.complete?
      assert finalized
    end
  end

  def test_low_level_provider_registration_is_not_a_public_surface
    refute Minitest::Testmon.respond_to?(:register_provider)
    registry = Minitest::Testmon::ProviderRegistry.new
    refute registry.respond_to?(:register)
    refute registry.respond_to?(:registered?)
  end

  def test_configured_provider_freezes_inventory_before_claims
    with_project do |project|
      path = write_file(File.join(project, "templates", "invoice.txt"), "total")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :templates, version: 1 do
        inventory :templates, root: :project, include: "templates/**/*.txt"
        facet :content, inventory: :templates, digest: :content, granularity: :file
        facet :membership, inventory: :templates, digest: :paths, granularity: :set
        claim :template_read, to: %i[templates content], path: :path
        claim :template_read, to: %i[templates membership]
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      assert_equal ["templates@1"], snapshot.registrations.map { |item| "#{item.name}@#{item.version}" }
      assert_equal 2, snapshot.context.artifacts.length

      session = snapshot.observe(selected: ["InvoiceTest#test_total"])
      session.record(Minitest::Testmon::Observation.build(
        kind: :template_read,
        provider: :templates,
        path: path,
        test_id: "InvoiceTest#test_total"
      ))
      report = session.finalize

      assert report.complete?
      assert_equal 2, report.dependencies.count { |item| item.test_id == "InvoiceTest#test_total" }
      assert report.artifacts.all? { |item| item.provider == :"templates@1" }
      content = report.artifacts.find { |item| item.facet == "content" }
      membership = report.artifacts.find { |item| item.facet == "membership" }
      assert_equal ["InvoiceTest#test_total"], content.test_ids
      assert_equal :suite, membership.scope
      assert_empty membership.test_ids
      assert(report.to_h.dig(:inventory, :claimed, :items).all? do |item|
        item.fetch(:test_ids) == ["InvoiceTest#test_total"]
      end)
    end
  end

  def test_using_receives_only_the_exact_frozen_facet_snapshot
    with_project do |project|
      write_file(File.join(project, "contracts", "v1.json"), "{}")
      received = nil
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :contracts, version: 1 do
        inventory :contracts, root: :project, include: "contracts/**/*.json"
        facet :contents, inventory: :contracts, digest: :content, granularity: :file
        claim :contract_lookup, to: %i[contracts contents], using: ->(_observation, snapshot) {
          received = snapshot
          snapshot.artifact_keys.first
        }
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(kind: :contract_lookup, test_id: "ContractTest#test_v1"))
      report = session.finalize

      assert report.complete?
      assert_instance_of Minitest::Testmon::FacetSnapshot, received
      assert_equal %i[name digest granularity scope artifact_keys], received.to_h.keys
      assert received.frozen?
      assert received.artifact_keys.frozen?
      assert_equal received.artifact_keys.sort, received.artifact_keys
    end
  end

  def test_suite_scoped_artifacts_discard_scheduler_dependent_test_ids
    with_project do |project|
      path = write_file(File.join(project, "config", "application.yml"), "value: one\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot, version: 1 do
        inventory :config, root: :project, include: "config/**/*.yml"
        facet :content,
          inventory: :config,
          digest: :content,
          granularity: :file,
          scope: :suite
        claim :config_read, to: %i[config content], path: :path
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :config_read,
        path: path,
        test_id: "ConfigTest#test_value"
      ))

      report = session.finalize
      artifact = report.artifacts.find { |item| item.provider == :"boot@1" }

      assert report.complete?
      assert_equal :suite, artifact.scope
      assert_empty artifact.test_ids
      assert_empty report.to_h.dig(:inventory, :suite_scoped, :items, 0, :test_ids)
      assert_includes(
        report.dependencies.map { |dependency| [dependency.test_id, dependency.artifact_key] },
        ["*", artifact.key]
      )
      assert_equal :suite, session.current_inputs.find { |input| input.id == artifact.to_input.id }.scope
    end
  end

  def test_suite_observation_cannot_widen_a_test_scoped_input
    with_project do |project|
      path = write_file(File.join(project, "config", "application.yml"), "value: one\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot, version: 1 do
        inventory :config, root: :project, include: "config/**/*.yml"
        facet :content, inventory: :config, digest: :content, granularity: :file
        claim :config_read, to: %i[config content], path: :path
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :config_read,
        path: path,
        scope: :suite
      ))

      report = session.finalize
      input = session.current_inputs.find { |item| item.relative_path == "config/application.yml" && item.facet == "content" }

      refute report.complete?
      assert_includes report.diagnostics, "ambiguous_context"
      assert_equal :test, input.scope
    end
  end

  def test_suite_evidence_reuses_an_existing_identical_whole_file_suite_input
    with_project do |project|
      path = write_file(File.join(project, "config/puma.rb"), "threads 0, 4\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :"rails.boot", Minitest::Testmon::Bundles::Rails81::BootDefinition.new, version: 1
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
      original = Minitest::Testmon::Observation.build(kind: :coverage_lines, path: path, test_id: "BrowserTest#test_first")
      normalized = Minitest::Testmon::ExecutionContext.with_evidence_scope(:suite) { session.record(original) }
      report = session.finalize

      assert report.complete?, report.diagnostics.inspect
      assert_equal :suite, normalized.scope
      assert_nil normalized.test_id
      refute_equal original.key, normalized.key
      boot_input = report.artifacts.find { |item| item.provider == :"rails.boot@1" && item.relative_path == "config/puma.rb" }
      assert_equal :suite, boot_input.scope
      assert report.dependencies.any? { |item| item.artifact_key == boot_input.key && item.test_id == "*" }
      assert_equal :test, Minitest::Testmon::ExecutionContext.evidence_scope
    end
  end

  def test_explicit_suite_evidence_promotes_a_known_content_file_artifact
    with_project do |project|
      path = write_file(File.join(project, "lib", "boot_helper.rb"), "VALUE = 4\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot_helper, version: 1 do |provider|
        provider.inventory :ruby, root: :project, include: "lib/**/*.rb"
        provider.facet :content, inventory: :ruby, digest: :content, granularity: :file
        provider.claim :boot_read, to: %i[ruby content], path: :path
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      original = Minitest::Testmon::Observation.build(
        kind: :boot_read,
        provider: :boot_helper,
        path: path,
        test_id: "BrowserTest#test_boot"
      )

      normalized = Minitest::Testmon::ExecutionContext.with_evidence_scope(:suite) do
        session.record(original)
      end
      report = session.finalize
      artifact = report.artifacts.find do |item|
        item.provider == :"boot_helper@1" && item.facet == "content"
      end

      assert report.complete?, report.diagnostics.inspect
      assert normalized.explicit_suite_evidence?
      assert_equal :suite, artifact.scope
      assert_equal "*", report.dependencies.find { |item| item.artifact_key == artifact.key }.test_id
    end
  end

  def test_explicit_suite_evidence_cannot_promote_a_contents_set_artifact
    with_project do |project|
      write_file(File.join(project, "lib", "boot_helper.rb"), "VALUE = 4\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot_helper, version: 1 do |provider|
        provider.inventory :ruby, root: :project, include: "lib/**/*.rb"
        provider.facet :contents, inventory: :ruby, digest: :contents, granularity: :set
        provider.claim :boot_read, to: %i[ruby contents]
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      Minitest::Testmon::ExecutionContext.with_evidence_scope(:suite) do
        session.record(Minitest::Testmon::Observation.build(
          kind: :boot_read,
          provider: :boot_helper,
          scope: :test
        ))
      end
      report = session.finalize

      refute report.complete?
      assert_includes report.diagnostics, "ambiguous_context"
    end
  end

  def test_unattributed_suite_observation_cannot_promote_a_whole_file_artifact
    with_project do |project|
      path = write_file(File.join(project, "lib", "boot_helper.rb"), "VALUE = 4\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot_helper, version: 1 do |provider|
        provider.inventory :ruby, root: :project, include: "lib/**/*.rb"
        provider.facet :content, inventory: :ruby, digest: :content, granularity: :file
        provider.claim :boot_read, to: %i[ruby content], path: :path
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :boot_read,
        provider: :boot_helper,
        path: path
      ))

      report = session.finalize

      refute report.complete?
      assert_includes report.diagnostics, "ambiguous_context"
    end
  end

  def test_late_activation_is_rejected_instead_of_publishing_an_unpersisted_suite_input
    with_project do |project|
      path = write_file(File.join(project, "config", "application.yml"), "value: one\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot, version: 1 do
        inventory :config, root: :project, include: "config/**/*.yml"
        facet :content, inventory: :config, digest: :content, granularity: :file
        claim :config_read, to: %i[config content], path: :path
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :config_read,
        path: path,
        reason: :late_activation
      ))

      report = session.finalize

      refute report.complete?
      assert_includes report.diagnostics, "late_activation"
    end
  end

  def test_ignore_cannot_clear_a_late_activation_failure
    with_project do |project|
      path = write_file(File.join(project, "config", "application.yml"), "value: one\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :boot, version: 1 do
        inventory :config, root: :project, include: "config/**/*.yml"
        facet :content, inventory: :config, digest: :content, granularity: :file
        claim :config_read, to: %i[config content], path: :path
        ignore :config_read, reason: "normally ignored", predicate: ->(_observation) { true }
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :config_read,
        path: path,
        reason: :late_activation
      ))

      report = session.finalize

      refute report.complete?
      assert_includes report.diagnostics, "late_activation"
      assert_equal :user_ignored, report.observations.fetch(0).reason
    end
  end

  def test_using_cannot_create_or_return_an_undeclared_artifact_key
    with_project do |project|
      write_file(File.join(project, "contracts", "v1.json"), "{}")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :contracts, version: 1 do
        inventory :contracts, root: :project, include: "contracts/**/*.json"
        facet :contents, inventory: :contracts, digest: :content, granularity: :file
        claim :contract_lookup, to: %i[contracts contents], using: ->(_observation, _snapshot) { "invented" }
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(kind: :contract_lookup, test_id: "ContractTest#test_v1"))
      report = session.finalize

      refute report.complete?
      assert_includes report.diagnostics, "claim_path_missing"
    end
  end

  def test_ignore_does_not_reclassify_non_path_observer_failures
    configuration = Minitest::Testmon::Configuration.new(cwd: Dir.pwd)
    configuration.provider :events, version: 1 do
      ignore :event_read, reason: "too broad", predicate: ->(_observation) { true }
    end
    session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
    session.record(Minitest::Testmon::Observation.build(
      kind: :event_read,
      reason: :observer_error
    ))

    report = session.finalize

    assert_equal :observer_error, report.observations.fetch(0).reason
  end

  def test_non_ruby_project_callsite_does_not_hide_opaque_file_evidence
    with_project do |project|
      rakefile = write_file(File.join(project, "Rakefile"), "File.read(\"config/settings.yml\")\n")
      write_file(File.join(project, "config/settings.yml"), "value: one\n")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :file_read,
        operation: :read,
        test_id: "RakeTaskTest#test_task",
        callsite: {path: rakefile, line: 1},
        reason: :opaque_c_call
      ))

      report = session.finalize

      refute report.complete?
      assert_equal :opaque_c_call, report.observations.fetch(0).reason
    end
  end

  def test_pathless_opaque_evidence_cannot_be_ignored_as_outside_project
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
      session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :file_read,
        operation: :read,
        test_id: "OpaqueTest#test_read",
        reason: :opaque_c_call
      ))

      report = session.finalize

      refute report.complete?
      assert_equal :opaque_c_call, report.observations.fetch(0).reason
    end
  end

  def test_ruby_source_inventory_matches_a_canonical_symlinked_base
    with_project do |project|
      source = write_file(File.join(project, "real/lib/example.rb"), "EXAMPLE = 1\n")
      File.symlink("real", File.join(project, "src"))
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :sources, version: 1 do
        inventory :ruby, root: :project, base: "src", include: "**/*.rb"
        facet :source, inventory: :ruby, digest: :ruby_source, granularity: :file
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)

      assert snapshot.current_inputs.any? { |input|
        input.relative_path == "real/lib/example.rb" && input.facet == "ruby_source"
      }
      assert snapshot.source_stable?

      File.binwrite(source, "EXAMPLE = 2\n")
      refute snapshot.source_stable?
    end
  end

  def test_snapshot_digest_detects_content_and_membership_drift
    with_project do |project|
      first = write_file(File.join(project, "catalog", "one.txt"), "one")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :catalog, version: 1 do
        inventory :catalog, root: :project, include: "catalog/**/*.txt"
        facet :content, inventory: :catalog, digest: :content, granularity: :file
        facet :membership, inventory: :catalog, digest: :paths, granularity: :set
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)

      assert snapshot.source_stable?
      File.binwrite(first, "changed")
      refute snapshot.source_stable?

      File.binwrite(first, "one")
      write_file(File.join(project, "catalog", "two.txt"), "two")
      refute snapshot.source_stable?
    end
  end

  def test_snapshot_digest_detects_a_symlink_retarget_with_the_same_realpath
    with_project do |project|
      target = write_file(File.join(project, "targets", "one.txt"), "one")
      link = File.join(project, "catalog", "one.txt")
      FileUtils.mkdir_p(File.dirname(link))
      File.symlink("../targets/one.txt", link)
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      configuration.provider :catalog, version: 1 do
        inventory :catalog, root: :project, include: "catalog/**/*.txt"
        facet :content, inventory: :catalog, digest: :content, granularity: :file
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)

      assert snapshot.source_stable?
      File.delete(link)
      File.symlink(target, link)
      refute snapshot.source_stable?
    end
  end

  def test_overlapping_providers_share_one_physical_artifact_and_keep_provenance
    with_project do |project|
      path = write_file(File.join(project, "shared", "input.txt"), "value")
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      %i[alpha beta].each do |provider_name|
        configuration.provider provider_name, version: 1 do
          inventory :inputs, root: :project, include: "shared/**/*.txt"
          facet :content, inventory: :inputs, digest: :content, granularity: :file
          claim :shared_read, to: %i[inputs content], path: :path
        end
      end
      snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
      session = snapshot.observe
      session.record(Minitest::Testmon::Observation.build(
        kind: :shared_read,
        path: path,
        test_id: "SharedTest#test_input"
      ))
      report = session.finalize

      assert report.complete?
      content = report.artifacts.select { |item| item.facet == "content" }
      assert_equal 2, content.length
      assert_equal 1, content.map(&:key).uniq.length
      assert_match(%r{\Aphysical/content/project:shared/input\.txt\z}, content.first.key)
      content_dependencies = report.dependencies.select { |item| item.artifact_key == content.first.key }
      assert_equal %w[alpha@1 beta@1], content_dependencies.map { |item| item.provider.to_s }.uniq.sort
    end
  end
end
