# frozen_string_literal: true

require "digest"

module MockPms
  module Admin
    # Idempotency-Key support for side-effecting admin POSTs (research R11).
    # The key row is claimed atomically before the handler runs; its response stays
    # null while in flight. Never use this for responses that contain secrets.
    module Idempotency
      module_function

      def call(key:, method:, path:, body:, &)
        return yield if key.nil? || key.to_s.strip.empty?

        digest = Digest::SHA256.hexdigest("#{method}\n#{path}\n#{body}")
        if claim(key, digest)
          run_claimed(key, &)
        else
          replay(key, digest)
        end
      end

      def dataset = MockPms.db[:admin_idempotency_keys]

      def claim(key, digest)
        !dataset.insert_conflict.returning(:key).insert(key: key, request_digest: digest).empty?
      end

      # Releases the key if the handler does not finish, whether it raised or threw
      # (Grape's error! uses throw), so the client can retry.
      def run_claimed(key)
        completed = false
        status, body = yield
        dataset.where(key: key).update(response_status: status, response_body: Sequel.pg_jsonb_wrap(body))
        completed = true
        [status, body]
      ensure
        dataset.where(key: key).delete unless completed
      end

      def replay(key, digest)
        row = dataset.where(key: key).first
        return error(409, "idempotency_in_progress", "a request with this key is still running") if row.nil?
        if row[:request_digest] != digest
          return error(422, "idempotency_key_mismatch",
                       "key reused with a different request")
        end
        if row[:response_status].nil?
          return error(409, "idempotency_in_progress",
                       "a request with this key is still running")
        end

        [row[:response_status], JSON.parse(JSON.generate(row[:response_body]))]
      end

      def error(status, code, message)
        [status, { "error" => { "code" => code, "message" => message } }]
      end
    end
  end
end
