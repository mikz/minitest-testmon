# frozen_string_literal: true

require_relative "test_helper"

class DocumentNotificationTest < Minitest::Test
  def test_document_render
    path = ROOT.join("config/documents/invoice.yml")
    document = ActiveSupport::Notifications.instrument(
      "render.document",
      identifier: path.to_s,
      metadata: {tags: ["acceptance"]}
    ) do
      YAML.safe_load_file(path)
    end
    assert_equal ENV.fetch("EXPECTED_DOCUMENT", "Invoice v1"), document.fetch("title")

    during = ENV["NOTIFICATION_DURING_MARKER"]
    if during
      listeners = ActiveSupport::Notifications.notifier.listeners_for("render.document")
      File.write(during, listeners.length.to_s)
    end
  end
end
