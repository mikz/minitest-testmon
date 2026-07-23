# frozen_string_literal: true

require_relative "test_helper"

class AdversarialHarnessSelfTest < Minitest::Test
  def test_preserved_publication_oracle_rejects_generation_inventory_and_publication_changes
    baseline = {"generation" => 4, "inventory" => {"claimed" => ["old"]}}
    changed = {
      "generation" => 5,
      "inventory" => {"claimed" => ["new"]},
      "publication" => {"published" => true, "reason" => nil}
    }

    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(baseline, changed)
    end
    assert_match "generation", error.message
    assert_match "inventory", error.message
    assert_match "publication", error.message
  end

  def test_full_recovery_oracle_rejects_partial_selection
    report = {
      "tests" => {"discovered" => %w[a b], "selected" => ["a"], "executed" => ["a"]},
      "publication" => {"published" => true}
    }

    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_full_recovery!(report)
    end
    assert_match "not full", error.message
  end

  def test_worker_merge_oracle_rejects_duplicate_result
    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_worker_results_complete!(
        selected: %w[a b],
        worker_results: [{"test_id" => "a"}, {"test_id" => "a"}, {"test_id" => "b"}]
      )
    end
    assert_match "duplicates=[\"a\"]", error.message
  end

  def test_worker_merge_oracle_rejects_missing_result
    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_worker_results_complete!(
        selected: %w[a b],
        worker_results: [{"test_id" => "a"}]
      )
    end
    assert_match "missing=[\"b\"]", error.message
  end

  def test_pruning_oracle_detects_removed_test_in_inventory_edge
    report = {
      "tests" => {"discovered" => [], "selected" => [], "executed" => []},
      "inventory" => {
        "claimed" => {"items" => [{"test_ids" => ["Removed#test_old"]}]}
      }
    }

    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_pruned!(report, "Removed#test_old")
    end
    assert_match "inventory", error.message
  end

  def test_suite_scope_oracle_rejects_claimed_only_artifact
    report = {
      "inventory" => {
        "suite_scoped" => {"items" => []},
        "claimed" => {"items" => [inventory_item(provider: "suite_inputs@1", path: "project:data/suite.txt")]}
      }
    }

    assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_suite_scoped!(
        report,
        provider: "suite_inputs@1",
        path_suffix: "data/suite.txt"
      )
    end
  end

  def test_physical_artifact_oracle_rejects_divergent_fingerprints
    report = {
      "inventory" => {
        "claimed" => {
          "items" => [
            inventory_item(provider: "overlap_a@1", path: "project:data/overlap.txt", fingerprint: "a"),
            inventory_item(provider: "overlap_b@1", path: "project:data/overlap.txt", fingerprint: "b")
          ]
        }
      }
    }

    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_one_physical_artifact!(
        report,
        path_suffix: "data/overlap.txt",
        providers: %w[overlap_a@1 overlap_b@1]
      )
    end
    assert_match "fingerprints", error.message
  end

  def test_background_oracle_rejects_late_access_attached_to_test
    report = {
      "observations" => {
        "claimed" => {
          "items" => [{
            "path" => "project:data/background.txt",
            "scope" => "test",
            "test_id" => "Background#test_01",
            "reason" => nil
          }]
        }
      }
    }

    error = assert_raises(MinitestTestmonAcceptance::AdversarialOracle::Mismatch) do
      MinitestTestmonAcceptance::AdversarialOracle.assert_late_background_observation!(
        report,
        path_suffix: "data/background.txt"
      )
    end
    assert_match "attached", error.message
  end

  def test_phase_five_acceptance_and_fixture_sources_compile
    sources = [
      *MinitestTestmonAcceptance::ROOT.glob("{adversarial,iseq_adversarial,rails_adversarial}_acceptance_test.rb"),
      *MinitestTestmonAcceptance::FIXTURES.join("adversarial").glob("**/*.rb"),
      MinitestTestmonAcceptance::FIXTURES.join("rails_app/test/high_volume_spool_test.rb")
    ]
    refute_empty sources
    sources.each do |source|
      assert RubyVM::InstructionSequence.compile_file(source.to_s), "failed to compile #{source}"
    end
  end

  def test_adversarial_fixture_exposes_every_external_barrier_without_product_test_seams
    source = MinitestTestmonAcceptance::FIXTURES.join("adversarial/test/race_input_test.rb").read
    lifecycle = MinitestTestmonAcceptance::FIXTURES.join("adversarial/test/lifecycle_test.rb").read
    acceptance = MinitestTestmonAcceptance::ROOT.join("adversarial_acceptance_test.rb").read

    %w[content membership symlink].each do |kind|
      assert_includes source, "wait_in_selection_gap(\"#{kind}\")"
    end
    assert_includes lifecycle, "ADVERSARIAL_BACKGROUND_BOUNDARY"
    assert_includes lifecycle, "parallelize_me!"
    assert_includes acceptance, "File.mkfifo"
    assert_includes acceptance, "baseline_bytes"
    refute_includes acceptance, "MINITEST_TESTMON_ACCEPTANCE_"
  end

  def test_high_volume_gate_observes_jsonl_before_release_and_has_explicit_bounds
    source = MinitestTestmonAcceptance::ROOT.join("rails_adversarial_acceptance_test.rb").read

    assert_includes source, "tmp/minitest-testmon/**/*.jsonl"
    assert_includes source, "MAX_SPOOL_BYTES"
    assert_includes source, "MAX_PROCESS_RSS_KIB"
    assert_operator source.index("jsonl_spools(project)"), :<, source.index('release.write("release")')
  end

  private

  def inventory_item(provider:, path:, fingerprint: "fingerprint")
    {
      "provider" => provider,
      "path" => path,
      "scope" => "suite",
      "fingerprint" => fingerprint
    }
  end
end
