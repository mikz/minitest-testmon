# frozen_string_literal: true

require_relative "test_helper"

class ProviderHarnessSelfTest < Minitest::Test
  def test_full_run_oracle_detects_filtering
    report = {"tests" => {"discovered" => %w[a b], "selected" => ["a"], "executed" => ["a"]}}

    assert_raises(MinitestTestmonAcceptance::ProviderOracle::Mismatch) do
      MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(report)
    end
  end

  def test_publication_oracle_detects_inventory_mutation
    baseline = {"generation" => 3, "inventory" => {"claimed" => []}}
    interrupted = {"generation" => 3, "inventory" => {"claimed" => ["new"]}}

    error = assert_raises(MinitestTestmonAcceptance::ProviderOracle::Mismatch) do
      MinitestTestmonAcceptance::ProviderOracle.assert_preserved_publication!(baseline, interrupted)
    end
    assert_match "inventory", error.message
  end

  def test_suggestion_oracle_detects_one_missing_code
    report = {"suggestions" => [{"code" => "uncovered_file"}]}

    assert_raises(MinitestTestmonAcceptance::ProviderOracle::Mismatch) do
      MinitestTestmonAcceptance::ProviderOracle.assert_suggestion_codes!(
        report,
        %w[outside_root uncovered_file]
      )
    end
  end

  def test_definition_oracle_detects_a_mutable_nested_collection
    snapshot = {
      "providers_frozen" => true,
      "mutation_error" => "FrozenError",
      "providers" => [{
        "id" => "ruby@1",
        "definition_frozen" => true,
        "collections_frozen" => {"inventories" => false}
      }]
    }

    assert_raises(MinitestTestmonAcceptance::ProviderOracle::Mismatch) do
      MinitestTestmonAcceptance::ProviderOracle.assert_definition_snapshot!(
        snapshot,
        expected_ids: ["ruby@1"]
      )
    end
  end

  def test_api_oracle_ignores_only_ancestor_load_order
    clean = {
      "TracePoint.instance" => {
        "enable" => {
          "owner" => "TracePoint",
          "source_location" => ["<internal:trace_point>", 261],
          "parameters" => [["key", "target"]],
          "arity" => -1
        }
      },
      "ancestors" => {"TracePoint" => ["TracePoint", "JSON::GeneratorMethods", "ActiveSupport::Tryable"]}
    }
    reordered = Marshal.load(Marshal.dump(clean))
    reordered.fetch("ancestors")["TracePoint"] =
      ["TracePoint", "ActiveSupport::Tryable", "JSON::GeneratorMethods"]

    assert MinitestTestmonAcceptance::ProviderOracle.assert_api_unchanged!(clean, reordered)
  end

  def test_api_oracle_detects_method_and_ancestor_mutations
    clean = {
      "TracePoint.instance" => {
        "enable" => {
          "owner" => "TracePoint",
          "source_location" => ["<internal:trace_point>", 261],
          "parameters" => [],
          "arity" => 0
        }
      },
      "ancestors" => {"TracePoint" => %w[TracePoint Object]}
    }
    changed_method = Marshal.load(Marshal.dump(clean))
    changed_method.dig("TracePoint.instance", "enable")["owner"] = "ObserverPatch"
    added_ancestor = Marshal.load(Marshal.dump(clean))
    added_ancestor.fetch("ancestors").fetch("TracePoint") << "ObserverPatch"

    method_error = assert_raises(MinitestTestmonAcceptance::ProviderOracle::Mismatch) do
      MinitestTestmonAcceptance::ProviderOracle.assert_api_unchanged!(clean, changed_method)
    end
    assert_match "method owners", method_error.message
    ancestor_error = assert_raises(MinitestTestmonAcceptance::ProviderOracle::Mismatch) do
      MinitestTestmonAcceptance::ProviderOracle.assert_api_unchanged!(clean, added_ancestor)
    end
    assert_match "added or removed", ancestor_error.message
  end

  def test_provider_acceptance_source_compiles_on_supported_ruby
    source = MinitestTestmonAcceptance::ROOT.join("provider_dsl_acceptance_test.rb")

    assert RubyVM::InstructionSequence.compile_file(source.to_s)
  end

  def test_provider_fixture_contains_frozen_dsl_spellings
    config = MinitestTestmonAcceptance::FIXTURES.join("provider_dsl/.minitest-testmon.rb").read

    assert_includes config, "config.provider :pricing_rules, version: 1"
    assert_includes config, "digest: :paths"
    assert_includes config, "granularity: :set"
    assert_includes config, "provider.observe_tracepoint :policy_loaded"
    assert_includes config, "provider.observe_notification :document_rendered"
    assert_includes config, "provider.observe_tracepoint :generated_file"
    assert_includes config, "provider.ignore :generated_file"
    assert_includes config, "provider.claim :resolver_loaded, to: [:resolver_files, :content], using: resolver"
    assert_includes config, "config.fileset :compat_templates"
  end
end
