# frozen_string_literal: true

require_relative "test_helper"

class TemplateCatalogTest < Minitest::Test
  def test_template_membership
    entries = TemplateCatalog.entries(ROOT.join("templates").to_s)
    expected = ENV.fetch("EXPECTED_TEMPLATES", "alpha.txt,beta.txt").split(",").sort
    assert_equal expected, entries
  end
end
