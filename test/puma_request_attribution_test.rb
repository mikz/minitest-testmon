# frozen_string_literal: true

require_relative "test_helper"
require "puma"
require "net/http"
require "timeout"
require "minitest/testmon/puma_request_attribution"

class PumaRequestAttributionTest < TestmonTestCase
  Context = Minitest::Testmon::ExecutionContext

  def test_standalone_requests_attribute_application_streaming_and_close_only_inside_the_boundary
    observed = Queue.new
    app = lambda do |_env|
      observed << Context.current_test
      body = Enumerator.new do |chunks|
        observed << Context.current_test
        chunks << "response"
      end
      body.define_singleton_method(:close) { observed << Context.current_test }
      [200, {"content-type" => "text/plain"}, body]
    end
    server = Puma::Server.new(app)
    server.singleton_class.prepend(Minitest::Testmon::PumaRequestAttribution)
    server.add_tcp_listener("127.0.0.1", 0)
    server.run
    uri = URI("http://127.0.0.1:#{server.connected_ports.first}/")

    [nil, "BrowserTest#test_gateway", nil].each do |test_id|
      if test_id
        Context.set(test_id)
        Context.begin_boundary
      end
      assert_equal "response", Net::HTTP.get(uri)
      assert_equal [test_id] * 3, Timeout.timeout(5) { 3.times.map { observed.pop } }
      Context.clear
      Context.end_boundary if test_id
    end
  ensure
    Context.clear
    Context.reset_boundaries!
    server&.stop(true)
  end
end
