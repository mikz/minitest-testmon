# frozen_string_literal: true

require_relative "test_helper"

class RailsAssetsTest < TestmonTestCase
  Rails81 = Minitest::Testmon::Bundles::Rails81

  def test_overlapping_paths_are_excluded_from_coarse_asset_inputs
    with_project do |project|
      asset_root = File.join(project, "vendor/javascript")
      nested = File.join(asset_root, "packages")
      sibling = File.join(project, "vendor/stylesheets")
      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(sibling)
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      install_rails_application([asset_root])

      definition = Rails81::AssetsDefinition.new(configuration)

      assert Rails81.overlapping?(asset_root, nested)
      assert Rails81.overlapping?(nested, asset_root)
      refute Rails81.overlapping?(asset_root, sibling)
      assert_equal [File.realpath(asset_root)], definition.instance_variable_get(:@asset_specs).map { |spec| spec.fetch(:path) }
      assert_empty definition.instance_variable_get(:@input_specs).select { |spec| spec.fetch(:path) == File.realpath(asset_root) }
    ensure
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    end
  end

  private

  def install_rails_application(asset_paths)
    raise "Rails unexpectedly loaded in the gem unit suite" if Object.const_defined?(:Rails, false)

    assets = Struct.new(:paths).new(asset_paths)
    configuration = Struct.new(:assets).new(assets)
    application = Struct.new(:config).new(configuration)
    rails = Module.new
    rails.define_singleton_method(:application) { application }
    Object.const_set(:Rails, rails)
  end
end
