# frozen_string_literal: true

require_relative "test_helper"

class RailsViewsTest < TestmonTestCase
  def test_debug_exception_templates_are_included_in_view_roots
    with_project do |project|
      templates = File.join(project, "actionpack/lib/action_dispatch/middleware/templates")
      write_file(File.join(templates, "rescues/diagnostics.html.erb"), "diagnostics")
      spec = Struct.new(:full_gem_path).new(File.join(project, "actionpack"))
      original = Gem.loaded_specs["actionpack"]
      Gem.loaded_specs["actionpack"] = spec

      assert_includes Minitest::Testmon::Bundles::Rails81.view_roots, templates
    ensure
      original ? Gem.loaded_specs["actionpack"] = original : Gem.loaded_specs.delete("actionpack")
    end
  end
end
