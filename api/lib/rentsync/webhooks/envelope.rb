# frozen_string_literal: true

module Rentsync
  module Webhooks
    # A verified body parsed and checked against 001's envelope (contracts/webhook-receiver.md
    # step 5). Anything else, including the mock's chaos malformations, is malformed_body.
    Envelope = Data.define(:id, :type, :occurred_at, :operator_id, :payload) do
      # The PMS fact's identity across paths (research R4); lease events have none.
      def business_key
        "#{type}:#{payload.dig('data', 'object', 'id')}" if Envelope::PAYMENT_TYPES.include?(type)
      end
    end

    class Envelope
      TYPES = %w[payment.created payment.reversed lease.updated tenant.moved_out].freeze
      PAYMENT_TYPES = %w[payment.created payment.reversed].freeze
      ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/

      # Fixed message text: never body content.
      class Invalid < StandardError
        def reason = "malformed_body"
      end

      def self.parse(body, event_id:)
        payload = json(body)
        raise Invalid, "not a JSON object" unless payload.is_a?(Hash)

        %w[id type occurred_at operator_id].each do |field|
          value = payload[field]
          raise Invalid, "#{field} missing" unless value.is_a?(String) && !value.empty?
        end
        check(payload, event_id)
        new(id: payload["id"], type: payload["type"], occurred_at: time(payload["occurred_at"]),
            operator_id: payload["operator_id"], payload: payload)
      end

      def self.json(body)
        text = body.to_s.dup.force_encoding(Encoding::UTF_8)
        raise Invalid, "body is not UTF-8" unless text.valid_encoding?

        JSON.parse(text)
      rescue JSON::ParserError
        raise Invalid, "body is not JSON"
      end

      def self.check(payload, event_id)
        raise Invalid, "id differs from PMS-Event-Id" unless payload["id"] == event_id
        raise Invalid, "unknown type" unless TYPES.include?(payload["type"])

        object = payload["data"].is_a?(Hash) ? payload["data"]["object"] : nil
        raise Invalid, "data.object is not an object" unless object.is_a?(Hash)
        return unless PAYMENT_TYPES.include?(payload["type"])
        raise Invalid, "payment without an id" unless object["id"].is_a?(String) && !object["id"].empty?
      end

      def self.time(value)
        raise Invalid, "occurred_at is not ISO 8601" unless ISO8601.match?(value)

        Time.iso8601(value).utc
      rescue ArgumentError
        raise Invalid, "occurred_at is not ISO 8601"
      end

      private_class_method :json, :check, :time
    end
  end
end
