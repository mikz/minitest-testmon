# frozen_string_literal: true

require "active_support/notifications"
require "minitest/autorun"
require "yaml"
require_relative "../lib/generated_loader"
require_relative "../lib/policy_loader"
require_relative "../lib/resolver_loader"
require_relative "../lib/template_catalog"

ROOT = Pathname.new(File.expand_path("..", __dir__))

class Minitest::Test
  def before_setup
    super
    marker = ENV["PROVIDER_TEST_MARKER"]
    if marker
      path = Pathname.new(marker)
      path.dirname.mkpath
      File.open(path, "a") { |file| file.puts "#{self.class}##{name}" }
    end
  end
end

Minitest.after_run do
  marker = ENV["NOTIFICATION_AFTER_MARKER"]
  next unless marker

  listeners = ActiveSupport::Notifications.notifier.listeners_for("render.document")
  File.write(marker, listeners.length.to_s)
end
