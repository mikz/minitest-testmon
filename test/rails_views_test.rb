# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

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

  def test_generated_template_identifier_resolves_to_its_physical_source
    with_project do |project|
      source = write_file(
        File.join(project, "app/views/user_mailer/password_reset.cs.md"),
        "reset"
      )

      assert_equal(
        File.realpath(source),
        Minitest::Testmon::Bundles::Rails81.physical_view_path("#{source}.text.mail_md")
      )
      missing = File.join(project, "app/views/missing.html.erb")
      assert_equal missing, Minitest::Testmon::Bundles::Rails81.physical_view_path(missing)
      assert_nil Minitest::Testmon::Bundles::Rails81.physical_view_path(nil)
    end
  end

  def test_external_gem_layout_is_ignored_but_unknown_outside_layout_fails_closed
    with_project do |project|
      external = Dir.mktmpdir("minitest-testmon-lookbook")
      unknown_root = Dir.mktmpdir("minitest-testmon-unknown-layout")
      layout = write_file(File.join(external, "app/views/layouts/lookbook.html.erb"), "lookbook")
      unknown = write_file(File.join(unknown_root, "unknown-layout.html.erb"), "unknown")
      project_view = write_file(File.join(project, "app/views/preview.html.erb"), "preview")
      script = <<~RUBY
        require "json"
        require "active_support/notifications"
        require "action_controller"
        require "minitest/testmon"

        ActionController::Base.append_view_path(#{File.join(project, "app/views").inspect})

        Spec = Struct.new(:full_gem_path)

        def report_for(project, path, gem_root: nil, unattributed: false)
          Gem.loaded_specs["lookbook"] = Spec.new(gem_root) if gem_root
          configuration = Minitest::Testmon::Configuration.new(cwd: project)
          definition = Minitest::Testmon::Bundles::Rails81::ViewsDefinition.new(configuration)
          configuration.provider :"rails.views", definition, version: 1
          session = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration).observe
          emit = proc do
            ActiveSupport::Notifications.instrument("render_layout.action_view", identifier: path)
          end
          Minitest::Testmon::ThreadContextPropagation.install!
          Minitest::Testmon::ExecutionContext.set("LookbookPreviewsTest#test_preview", thread_sources: {}.freeze)
          unattributed ? Thread.new(&emit).value : emit.call
          Minitest::Testmon::ExecutionContext.clear
          session.finalize.to_h
        ensure
          Gem.loaded_specs.delete("lookbook")
        end

        ignored = report_for(#{project.inspect}, #{layout.inspect}, gem_root: #{external.inspect})
        rejected = report_for(#{project.inspect}, #{unknown.inspect})
        puts JSON.generate(ignored)
        puts JSON.generate(rejected)
        puts JSON.generate(report_for(#{project.inspect}, #{layout.inspect}, gem_root: #{external.inspect}, unattributed: true))
        puts JSON.generate(report_for(#{project.inspect}, #{project_view.inspect}, unattributed: true))
      RUBY
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I#{File.join(File.expand_path("..", __dir__), "lib")}",
        "-e",
        script,
        chdir: project
      )

      assert status.success?, stderr
      ignored, rejected, unattributed_external, unattributed_project = stdout.lines.map { |line| JSON.parse(line) }
      assert_equal true, unattributed_external.fetch("complete")
      assert_equal [], unattributed_external.fetch("diagnostics")
      assert_equal false, unattributed_project.fetch("complete")
      assert_includes unattributed_project.fetch("diagnostics"), "ambiguous_context"
      assert_equal true, ignored.fetch("complete")
      ignored_item = ignored.dig("observations", "ignored", "items").find do |item|
        item.fetch("operation") == "render_layout.action_view"
      end
      refute_nil ignored_item
      assert_equal "user_ignored", ignored_item.fetch("reason")
      assert_equal File.realpath(layout), ignored_item.fetch("path")

      assert_equal false, rejected.fetch("complete")
      assert_includes rejected.fetch("diagnostics"), "outside_root"
      rejected_item = rejected.dig("observations", "unresolved", "items").find do |item|
        item.fetch("operation") == "render_layout.action_view"
      end
      refute_nil rejected_item
      assert_equal "outside_root", rejected_item.fetch("reason")
      assert_equal File.realpath(unknown), rejected_item.fetch("path")
    ensure
      FileUtils.remove_entry(external) if external && File.exist?(external)
      FileUtils.remove_entry(unknown_root) if unknown_root && File.exist?(unknown_root)
    end
  end
end
