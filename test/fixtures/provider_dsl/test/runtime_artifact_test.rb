# frozen_string_literal: true

require_relative "test_helper"

class RuntimeArtifactTest < Minitest::Test
  def test_runtime_file_cannot_join_frozen_inventory
    return pass unless ENV["PROBE_RUNTIME_ARTIFACT"] == "1"

    path = ROOT.join("config/pricing/runtime.yml")
    path.write("runtime: true\n")
    assert_equal({"runtime" => true}, YAML.safe_load_file(path))
  ensure
    path&.delete if path&.exist?
  end
end
