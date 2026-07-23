# frozen_string_literal: true

require_relative "test_helper"

class LocaleTest < ActiveSupport::TestCase
  def test_locale
    assert_equal ENV.fetch("EXPECTED_LOCALE", "Hello from locale v1"), I18n.t("acceptance.greeting")
    assert_equal(
      ENV.fetch("EXPECTED_RUNTIME_LOCALE", "Hello from runtime locale v1"),
      I18n.t("acceptance.runtime_greeting")
    )
  end
end
