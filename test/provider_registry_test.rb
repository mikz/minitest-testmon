# frozen_string_literal: true

require_relative "test_helper"

class ProviderRegistryTest < TestmonTestCase
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
      assert report.artifacts.all? { |item| item.test_ids == ["InvoiceTest#test_total"] }
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
      assert_equal 2, report.artifacts.length
      assert_equal 1, report.artifacts.map(&:key).uniq.length
      assert_match(%r{\Aphysical/content/project:shared/input\.txt\z}, report.artifacts.first.key)
      assert_equal %w[alpha@1 beta@1], report.dependencies.map { |item| item.provider.to_s }.uniq.sort
      assert_equal [report.artifacts.first.key], report.dependencies.map(&:artifact_key).uniq
    end
  end
end
