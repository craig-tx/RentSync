# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module Rentsync
  module Auth
    # Operator sessions (research R11): the cookie holds 32 random bytes, the table holds only
    # their SHA-256. Sessions end after 12 hours idle, 7 days after sign-in, or at sign-out.
    module Sessions
      IDLE_S = 12 * 3600
      ABSOLUTE_S = 7 * 86_400

      module_function

      # Returns the cookie token.
      def create!(operator)
        token = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
        now = Clock.now
        Session.create(operator_id: operator.id, token_sha256: Sequel.blob(token_digest(token)),
                       csrf_secret: Sequel.blob(SecureRandom.random_bytes(32)), created_at: now, last_seen_at: now)
        token
      end

      # The live session for this token, with last_seen_at moved to now; nil otherwise.
      def find(token)
        return nil if token.nil? || token.empty?

        now = Clock.now
        session = Session.first(token_sha256: Sequel.blob(token_digest(token)), revoked_at: nil)
        return nil unless session && live?(session, now)

        session.this.update(last_seen_at: now)
        session.values[:last_seen_at] = now
        session
      end

      def revoke!(token)
        return if token.nil? || token.empty?

        Session.where(token_sha256: Sequel.blob(token_digest(token)), revoked_at: nil).update(revoked_at: Clock.now)
      end

      def live?(session, now)
        session.last_seen_at > now - IDLE_S && session.created_at > now - ABSOLUTE_S
      end

      def token_digest(token) = Digest::SHA256.digest(token)
    end
  end
end
