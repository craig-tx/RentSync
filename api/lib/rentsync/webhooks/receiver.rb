# frozen_string_literal: true

module Rentsync
  module Webhooks
    # POST /webhooks/pms (contracts/webhook-receiver.md): a plain Rack endpoint ahead of the
    # session middleware and Grape, so it reads the exact body bytes. The signature is the
    # authentication; nothing in the body is read before it passes.
    class Receiver
      include Logging::Loggable

      PATH = "/webhooks/pms"
      MAX_BYTES = 256 * 1024
      STATUS = { "body_too_large" => 413, "missing_signature" => 401, "bad_signature" => 401,
                 "stale_timestamp" => 401 }.freeze
      # Fixed text for each reason: never body content, header values or secrets.
      MESSAGES = {
        "body_too_large" => "body exceeds #{MAX_BYTES} bytes",
        "missing_signature" => "PMS-Signature is missing or malformed",
        "bad_signature" => "signature does not verify",
        "stale_timestamp" => "signature timestamp is outside the 300 s window",
        "malformed_body" => "body is not a valid event envelope",
        "unknown_operator" => "no connection for this PMS operator",
        "no_active_connection" => "the connection for this PMS operator is not active",
        "conflicting_duplicate" => "event ID already recorded with a different body"
      }.freeze

      def call(env)
        env["rentsync.answered_by"] = "#{self.class.name}#call"
        # Rack's map matches prefixes; only the exact path is the endpoint.
        return error(404, "not_found", "no route") unless env["PATH_INFO"].to_s.empty? || env["PATH_INFO"] == "/"
        return error(405, "method_not_allowed", "use POST") unless env["REQUEST_METHOD"] == "POST"

        receive(env)
      end

      private

      def receive(env)
        delivery = Delivery.from_env(env, correlation_id: Thread.current[:correlation_id], received_at: Clock.now)
        body = read_body(env)
        result = process(env, body, delivery)
        respond(result, delivery)
      rescue StandardError => e
        log.error("webhook not recorded", error: e.class.name)
        record_failure(body, delivery)
        error(500, "internal_error")
      end

      def process(env, body, delivery)
        return Recorder.reject!("body_too_large", body: body, delivery: delivery) if body.bytesize > MAX_BYTES

        clients = PmsClient.active.order(:id).all
        index = Signature.verify!(header: env["HTTP_PMS_SIGNATURE"], body: body,
                                  secrets: clients.map(&:signing_secret_plaintext), now: delivery.received_at)
        envelope = Envelope.parse(body, event_id: env["HTTP_PMS_EVENT_ID"])
        Recorder.record!(pms_client: clients[index], envelope: envelope, body: body, delivery: delivery)
      rescue Signature::Failure => e
        Recorder.reject!(e.reason, body: body, delivery: delivery,
                                   pms_client_id: e.secret_index && clients[e.secret_index].id)
      rescue Envelope::Invalid => e
        Recorder.reject!(e.reason, body: body, delivery: delivery, pms_client_id: clients[index].id)
      end

      # At most MAX_BYTES + 1 bytes, whatever Content-Length claims.
      def read_body(env)
        input = env["rack.input"]
        (input&.read(MAX_BYTES + 1) || "").b
      end

      def respond(result, delivery)
        if result.outcome == "rejected"
          status = STATUS.fetch(result.reason, 422)
          return error(status, result.reason, MESSAGES.fetch(result.reason))
        end

        json(200, outcome: result.outcome, event_id: delivery.event_id)
      end

      # Best effort: the failed transaction rolled back, so this receipt is written on its own.
      def record_failure(body, delivery)
        return unless delivery

        Recorder.reject!("internal_error", body: body.to_s, delivery: delivery)
      rescue StandardError => e
        log.error("webhook failure receipt not written", error: e.class.name)
      end

      def error(status, code, message = nil)
        json(status, error: message ? { code: code, message: message } : { code: code })
      end

      def json(status, payload) = [status, { "content-type" => "application/json" }, [JSON.generate(payload)]]
    end
  end

  App.endpoints[Webhooks::Receiver::PATH] = Webhooks::Receiver.new
end
