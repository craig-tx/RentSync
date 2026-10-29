# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module Rentsync
  module Pms
    # Connecting an operator's PMS account (research R7, FR-002, FR-008). start! records an
    # attempt (the state's digest, the encrypted PKCE verifier, a 10-minute expiry) and returns
    # the PMS authorize URL; finish! takes the callback, uses the attempt once, exchanges the
    # code and links the PMS operator to the RentSync operator.
    class Connect
      include Logging::Loggable

      # The callback's state is unknown, used, expired or another operator's: nothing is stored.
      class InvalidState < StandardError; end
      # This deployment has no PMS client yet (bin/setup registers one).
      class NotRegistered < StandardError; end

      Result = Struct.new(:outcome, :error_code, :connection, keyword_init: true)

      def initialize(request: nil)
        @request = request
      end

      def start!(operator)
        client = active_client
        state = random
        verifier = random
        now = Clock.now
        ConnectionAttempt.create_with_secrets(
          { operator_id: operator.id, state_sha256: Sequel.blob(digest(state)), created_at: now,
            expires_at: now + ConnectionAttempt::TTL_S },
          code_verifier: verifier
        )
        OAuth.new(client: client, request: @request).authorize_url(state: state, code_verifier: verifier)
      end

      def finish!(operator, state:, code: nil, error: nil)
        attempt = use!(operator, state)
        return finish(attempt, "denied", error) if error == "access_denied"
        return finish(attempt, "failed", error.to_s[0, 64]) if error
        return finish(attempt, "failed", "missing_code") if code.to_s.empty?

        client = active_client
        tokens = OAuth.new(client: client, request: @request)
                      .exchange_code(code: code, code_verifier: attempt.code_verifier_plaintext)
        connection, problem = link(operator, client, tokens)
        problem ? finish(attempt, "failed", problem) : finish(attempt, "connected", nil, connection)
      rescue OAuth::Rejected => e
        finish(attempt, "failed", e.code)
      rescue OAuth::Unavailable
        finish(attempt, "failed", "pms_unavailable")
      end

      private

      def active_client = PmsClient.active.first(pms_key: Registration::PMS_KEY) || raise(NotRegistered)

      # Single use: only the first UPDATE ... WHERE used_at IS NULL changes the row.
      def use!(operator, state)
        attempt = state.to_s.empty? ? nil : ConnectionAttempt.first(state_sha256: Sequel.blob(digest(state)))
        raise InvalidState, "unknown state" unless attempt && attempt.operator_id == operator.id

        now = Clock.now
        if attempt.expires_at <= now
          ConnectionAttempt.where(id: attempt.id, used_at: nil, outcome: nil).update(outcome: "expired")
          raise InvalidState, "expired state"
        end
        used = ConnectionAttempt.where(id: attempt.id, used_at: nil).where { expires_at > now }.update(used_at: now)
        raise InvalidState, "used state" if used.zero?

        attempt
      end

      # Reconnecting the same PMS operator reuses its row (FR-008). Returns [connection, nil] or
      # [nil, error_code].
      def link(operator, client, tokens)
        Rentsync.db.transaction do
          taken = PmsConnection.where(pms_client_id: client.id, pms_operator_id: tokens.pms_operator_id)
                               .for_update.first
          next [nil, "pms_operator_taken"] if taken && taken.operator_id != operator.id

          mine = taken || PmsConnection.where(operator_id: operator.id, pms_client_id: client.id).for_update.first
          next [nil, "different_pms_account"] if mine && mine.pms_operator_id != tokens.pms_operator_id

          [mine ? reconnect(mine, tokens) : create(operator, client, tokens), nil]
        end
      rescue Sequel::UniqueConstraintViolation
        [nil, "pms_operator_taken"] # a concurrent callback linked it first
      end

      def create(operator, client, tokens)
        now = Clock.now
        PmsConnection.create_with_secrets(
          { operator_id: operator.id, pms_client_id: client.id, pms_operator_id: tokens.pms_operator_id,
            pms_operator_name: tokens.pms_operator_name.to_s, status: "active", connected_at: now,
            access_expires_at: now + tokens.expires_in },
          access_token: tokens.access_token, refresh_token: tokens.refresh_token
        )
      end

      def reconnect(connection, tokens)
        now = Clock.now
        connection.this.update(
          connection.seal(access_token: tokens.access_token, refresh_token: tokens.refresh_token).merge(
            pms_operator_name: tokens.pms_operator_name.to_s, status: "active", connected_at: now,
            disconnected_at: nil, access_expires_at: now + tokens.expires_in, renewal_lease_until: nil,
            renewal_failures: 0, last_renewal_error: nil
          )
        )
        connection.refresh
      end

      def finish(attempt, outcome, error_code, connection = nil)
        attempt.this.update(outcome: outcome, error_code: error_code)
        log.info("connection attempt finished", outcome: outcome, error_code: error_code,
                                                connection_id: connection&.public_id)
        Result.new(outcome: outcome, error_code: error_code, connection: connection)
      end

      def random = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)

      def digest(value) = Digest::SHA256.digest(value)
    end
  end
end
