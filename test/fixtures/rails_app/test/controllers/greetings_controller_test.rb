# frozen_string_literal: true

require_relative "../test_helper"

class GreetingsControllerTest < ActionDispatch::IntegrationTest
  def test_show
    get "/greeting"
    assert_response :success
    assert_includes response.body, ENV.fetch("EXPECTED_TEMPLATE", "Hello from template v1")

    get "/greeting", params: {runtime: "1"}
    assert_response :success
    assert_includes response.body,
      ENV.fetch("EXPECTED_RUNTIME_TEMPLATE", "Hello from runtime template v1")
  end
end
