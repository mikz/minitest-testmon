# frozen_string_literal: true

require_relative "test_helper"

class IgnoredArtifactTest < Minitest::Test
  def test_generated_file_is_user_ignored
    assert_equal "generated input", GeneratedLoader.load(ROOT.join("config/pricing/skipped.generated").to_s)
  end
end
