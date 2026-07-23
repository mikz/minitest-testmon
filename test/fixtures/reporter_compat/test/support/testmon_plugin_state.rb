# frozen_string_literal: true

module ReporterTestmonPluginState
  module_function

  def feature_loaded?
    $LOADED_FEATURES.any? do |feature|
      feature.tr("\\", "/").end_with?("/minitest/testmon_plugin.rb")
    end
  end

  def extension_registered?
    return false unless defined?(Minitest) && Minitest.respond_to?(:extensions)

    Minitest.extensions.any? { |extension| extension.to_s == "testmon" }
  end

  def active?
    feature_loaded? && extension_registered?
  end

  def snapshot
    {
      "testmon_plugin_loaded" => feature_loaded?,
      "testmon_extension_registered" => extension_registered?
    }
  end
end
