# frozen_string_literal: true

require "net/http"
require "openssl"

module MockPms
  # The Delivery Sequel model (models/events.rb) doubles as this namespace.
  class Delivery
    # Net::HTTP POST with 10 s timeouts. Any 2xx is success (contracts/webhooks.md).
    class Transport
      TIMEOUT = 10

      def post(url, body:, headers:)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = body
        response = http.request(request)
        code = response.code.to_i
        { outcome: (200..299).cover?(code) ? "success" : "http_error", http_status: code }
      rescue Net::OpenTimeout, Net::ReadTimeout
        { outcome: "timeout", http_status: nil }
      rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError
        { outcome: "connection_error", http_status: nil }
      end
    end
  end
end
