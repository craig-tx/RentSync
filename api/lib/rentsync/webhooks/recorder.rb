# frozen_string_literal: true

require "digest"

module Rentsync
  module Webhooks
    # What the receiver knows about a delivery from its headers (001 webhooks.md "Headers").
    # Header values are capped: before the signature passes they are unauthenticated input.
    Delivery = Data.define(:delivery_id, :attempt, :event_id, :event_type, :correlation_id, :received_at) do
      def self.from_env(env, correlation_id:, received_at:)
        attempt = env["HTTP_PMS_DELIVERY_ATTEMPT"].to_s
        new(delivery_id: cap(env["HTTP_PMS_DELIVERY_ID"]), attempt: attempt.match?(/\A\d{1,6}\z/) ? attempt.to_i : nil,
            event_id: cap(env["HTTP_PMS_EVENT_ID"]), event_type: cap(env["HTTP_PMS_EVENT_TYPE"]),
            correlation_id: correlation_id, received_at: received_at)
      end

      def self.cap(value) = value && value.to_s[0, 100]
    end

    # Records a verified delivery once (research R3 steps 5-6, R4) and writes its receipt (R10), in
    # one transaction: the receiver answers only after it commits (FR-011).
    module Recorder
      REASONS = %w[missing_signature bad_signature stale_timestamp body_too_large malformed_body
                   unknown_operator no_active_connection conflicting_duplicate internal_error].freeze

      # event_type: the verified envelope's type, once the body has been read.
      Result = Data.define(:outcome, :reason, :raw_event_id, :duplicate_of_path, :event_type) do
        def initialize(outcome:, reason: nil, raw_event_id: nil, duplicate_of_path: nil, event_type: nil) = super
      end

      module_function

      def record!(pms_client:, envelope:, body:, delivery:)
        receipt = { pms_client_id: pms_client.id, event_id: envelope.id, event_type: envelope.type }
        Rentsync.db.transaction do
          connection = PmsConnection.where(pms_client_id: pms_client.id, pms_operator_id: envelope.operator_id).first
          unless connection && PmsConnection::LIVE.include?(connection.status)
            reason = connection ? "no_active_connection" : "unknown_operator"
            next reject!(reason, body: body, delivery: delivery,
                                 **receipt, connection_id: connection&.id, operator_id: connection&.operator_id)
          end

          result = insert(pms_client, connection, envelope, body, delivery).with(event_type: envelope.type)
          write_receipt(result, body: body, delivery: delivery, **receipt,
                                connection_id: connection.id, operator_id: connection.operator_id)
          result
        end
      end

      # Receipt columns for a delivery whose signature verified but which was still refused
      # (stale, or malformed): the operator, event ID and type read from the authenticated body,
      # never from headers, so the rejection shows on that operator's health page (US4).
      def attribution(pms_client, body)
        found = fields_in(body)
        connection = found["operator_id"] &&
                     PmsConnection.where(pms_client_id: pms_client.id, pms_operator_id: found["operator_id"]).first
        { pms_client_id: pms_client.id, connection_id: connection&.id, operator_id: connection&.operator_id,
          event_id: found["id"], event_type: Envelope::TYPES.include?(found["type"]) ? found["type"] : nil }
      end

      # Top-level id, type and operator_id from a body that may not parse (a truncated body still
      # starts with them).
      def fields_in(body)
        text = body.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
        parsed = begin
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end
        %w[id type operator_id].to_h do |key|
          value = parsed.is_a?(Hash) ? parsed[key] : text[/"#{key}"\s*:\s*"([^"\\]{1,100})"/, 1]
          [key, value.is_a?(String) && !value.empty? ? value[0, 100] : nil]
        end
      end

      # A rejection's receipt, with whatever is known about the delivery.
      def reject!(reason, body:, delivery:, **known)
        raise ArgumentError, "unknown reason #{reason}" unless REASONS.include?(reason)

        result = Result.new(outcome: "rejected", reason: reason)
        write_receipt(result, body: body, delivery: delivery, **known)
        result
      end

      def write_receipt(result, body:, delivery:, **known)
        Rentsync.db[:webhook_receipts].insert(
          received_at: delivery.received_at, delivery_id: delivery.delivery_id, delivery_attempt: delivery.attempt,
          event_id: delivery.event_id, event_type: delivery.event_type, correlation_id: delivery.correlation_id,
          outcome: result.outcome, reason: result.reason, duplicate_of_path: result.duplicate_of_path,
          raw_event_id: result.raw_event_id, body_bytes: body.to_s.bytesize,
          body_sha256: Sequel.blob(Digest::SHA256.digest(body.to_s)), **known
        )
      end

      # INSERT ... ON CONFLICT DO NOTHING over both unique keys; on a conflict, the stored row says
      # which outcome this is.
      def insert(pms_client, connection, envelope, body, delivery)
        digest = Digest::SHA256.digest(body)
        id = Rentsync.db[:raw_events].insert_conflict.returning(:id).insert(
          pms_client_id: pms_client.id, connection_id: connection.id, event_id: envelope.id,
          business_key: envelope.business_key, event_type: envelope.type, occurred_at: envelope.occurred_at,
          received_at: delivery.received_at, arrival_path: "webhook", payload_raw: Sequel.blob(body),
          payload: Sequel.pg_jsonb_wrap(envelope.payload), payload_sha256: Sequel.blob(digest),
          correlation_id: delivery.correlation_id
        ).first&.fetch(:id)
        return Result.new(outcome: "recorded", raw_event_id: id) if id

        existing(pms_client, envelope, digest)
      end

      def existing(pms_client, envelope, digest)
        events = Rentsync.db[:raw_events].where(pms_client_id: pms_client.id)
        same_id = events.where(event_id: envelope.id).select(:id, :arrival_path, :payload_sha256).first
        if same_id
          return Result.new(outcome: "rejected", reason: "conflicting_duplicate", raw_event_id: same_id[:id]) \
            unless same_id[:payload_sha256] == digest

          return Result.new(outcome: "duplicate", raw_event_id: same_id[:id], duplicate_of_path: same_id[:arrival_path])
        end

        # A business-key conflict: the other path recorded this fact first, with its own bytes.
        same_fact = events.where(business_key: envelope.business_key).select(:id, :arrival_path).first
        raise "raw event conflict with no matching row" unless same_fact

        Result.new(outcome: "duplicate", raw_event_id: same_fact[:id], duplicate_of_path: same_fact[:arrival_path])
      end
    end
  end
end
