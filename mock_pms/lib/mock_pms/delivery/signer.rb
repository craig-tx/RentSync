# frozen_string_literal: true

require "openssl"

module MockPms
  # The Delivery Sequel model (models/events.rb) doubles as this namespace.
  class Delivery
    # PMS-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
    # over the exact bytes sent (research R10, contracts/webhooks.md).
    module Signer
      module_function

      def sign(secret:, t:, body:)
        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{t}.".b + body.to_s.b)
      end

      def header(secret:, t:, body:) = "t=#{t},v1=#{sign(secret: secret, t: t, body: body)}"

      def verify(header:, secret:, body:)
        parts = header.to_s.split(",").map { |kv| kv.split("=", 2) }.select { |pair| pair.size == 2 }.to_h
        return false unless parts["t"] && parts["v1"]

        Rack::Utils.secure_compare(sign(secret: secret, t: parts["t"], body: body), parts["v1"])
      end
    end
  end
end
