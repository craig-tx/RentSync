# frozen_string_literal: true

require "openssl"

module Rentsync
  module Webhooks
    # PMS-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")> (001
    # webhooks.md). The signature is checked before the timestamp, and both before the body is
    # read (contracts/webhook-receiver.md steps 2-4).
    module Signature
      TOLERANCE_S = 300
      FORMAT = /\At=(\d{1,12}),v1=(\h{64})\z/

      # Carries a receipt reason. Messages are fixed text: never a header, body or secret.
      class Failure < StandardError
        attr_reader :reason, :secret_index

        # secret_index: which secret verified, when the failure came after the signature passed.
        def initialize(reason, secret_index = nil)
          @reason = reason
          @secret_index = secret_index
          super("webhook #{reason}")
        end
      end

      module_function

      # Returns the index in `secrets` of the one that signed `body`, or raises Failure.
      def verify!(header:, body:, secrets:, now:)
        timestamp, signature = parse(header)
        index = secrets.index { |secret| matches?(secret, timestamp: timestamp, signature: signature, body: body) }
        raise Failure, "bad_signature" unless index
        raise Failure.new("stale_timestamp", index) if (now.to_i - timestamp).abs > TOLERANCE_S

        index
      end

      def parse(header)
        match = FORMAT.match(header.to_s.strip)
        raise Failure, "missing_signature" unless match

        [Integer(match[1], 10), match[2].downcase]
      end

      def matches?(secret, timestamp:, signature:, body:)
        expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.".b + body.to_s.b)
        expected.bytesize == signature.bytesize && OpenSSL.fixed_length_secure_compare(expected, signature)
      end
    end
  end
end
