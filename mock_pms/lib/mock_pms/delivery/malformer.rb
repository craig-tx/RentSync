# frozen_string_literal: true

module MockPms
  # The Delivery Sequel model (models/events.rb) doubles as this namespace.
  class Delivery
    # Chaos-malformed bodies (research R7). The signature is computed over the bytes
    # this returns, so a malformed body still verifies; only parsing catches it.
    module Malformer
      module_function

      def apply(kind, body)
        case kind
        when "truncate" then body.byteslice(0, body.bytesize / 2)
        when "drop_field" then JSON.generate(JSON.parse(body).except("data"))
        when "bad_type"
          parsed = JSON.parse(body)
          parsed["occurred_at"] = Time.iso8601(parsed["occurred_at"]).to_i
          JSON.generate(parsed)
        else body
        end
      end
    end
  end
end
