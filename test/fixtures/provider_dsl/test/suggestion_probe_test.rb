# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SuggestionProbeTest < Minitest::Test
  def test_structured_suggestion_inputs
    return pass unless ENV["PROBE_SUGGESTIONS"] == "1"

    # standard:disable Style/FileRead
    assert_equal "uncovered input\n", File.open(ROOT.join("data/uncovered.txt"), &:read)
    # standard:enable Style/FileRead
    assert_equal "opaque input\n", File.read(ROOT.join("data/opaque.txt"))
    assert_equal ["one.txt"], Dir.children(ROOT.join("uncovered_templates")).sort

    Dir.mktmpdir("minitest-testmon-outside-") do |directory|
      outside = File.join(directory, "outside.txt")
      File.write(outside, "outside\n")
      assert_equal "outside\n", File.read(outside)
    end

    path = ROOT.join("config/documents/invoice.yml").to_s
    ActiveSupport::Notifications.instrument("audit.document", identifier: path)
    pass
  end
end
