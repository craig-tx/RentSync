# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module MockPms
  module OAuth
    # An RFC 6749 error: `code` is the OAuth error string, `status` the HTTP status.
    class Error < StandardError
      attr_reader :code, :status

      def initialize(code, description = code, status: 400)
        super(description)
        @code = code
        @status = status
      end
    end

    # Authorization-code flow with rotating refresh tokens (research R3). Codes and
    # tokens are opaque random strings; only their SHA-256 digests are stored, and
    # single use is enforced by a conditional UPDATE in the issuing transaction.
    module Service
      CODE_TTL = 60

      module_function

      def digest(raw) = Digest::SHA256.hexdigest(raw.to_s)

      def random_token = SecureRandom.urlsafe_base64(32)

      def authenticate_client(client_id, secret)
        client = Client.first(id: client_id.to_s)
        valid = client && Rack::Utils.secure_compare(client.secret_digest, digest(secret))
        raise Error.new("invalid_client", "client authentication failed", status: 401) unless valid

        client
      end

      def approve!(client:, operator:, redirect_uri:, code_challenge: nil, code_challenge_method: nil)
        raw = random_token
        MockPms.db.transaction do
          grant = active_grant(client, operator)
          AuthorizationCode.create(code_digest: digest(raw), grant_seq: grant.seq, redirect_uri: redirect_uri,
                                   code_challenge: code_challenge, code_challenge_method: code_challenge_method,
                                   expires_at: Clock.now + CODE_TTL)
        end
        raw
      end

      def exchange_code!(client:, code:, redirect_uri:, code_verifier: nil)
        MockPms.db.transaction do
          row = claim(MockPms.db[:authorization_codes], :code_digest, digest(code))
          raise Error, "invalid_grant" unless row

          grant = Grant[row[:grant_seq]]
          raise Error, "invalid_grant" unless grant&.active? && grant.client_seq == client.seq
          raise Error.new("invalid_grant", "redirect_uri mismatch") unless row[:redirect_uri] == redirect_uri
          raise Error.new("invalid_grant", "PKCE verification failed") unless pkce_ok?(row, code_verifier)

          issue_tokens(grant)
        end
      end

      def refresh!(client:, refresh_token:)
        MockPms.db.transaction do
          row = claim(MockPms.db[:refresh_tokens], :token_digest, digest(refresh_token))
          raise Error, "invalid_grant" unless row

          grant = Grant[row[:grant_seq]]
          raise Error, "invalid_grant" unless grant&.active? && grant.client_seq == client.seq

          issue_tokens(grant)
        end
      end

      # Order (data-model.md): unknown -> invalid, revoked -> invalid, expired -> expired.
      def validate_access_token(raw)
        return [:invalid, nil] if raw.nil? || raw.empty?

        token = AccessToken[digest(raw)]
        return [:invalid, nil] unless token

        grant = Grant[token.grant_seq]
        return [:invalid, nil] unless grant&.active?
        return [:expired, nil] if token.expires_at <= Clock.now

        [:valid, grant]
      end

      def revoke!(grant)
        Grant.where(seq: grant.seq, revoked_at: nil).update(revoked_at: Clock.now)
        grant.refresh
      end

      def active_grant(client, operator)
        Grant.active.first(client_seq: client.seq, operator_seq: operator.seq) ||
          Grant.create(client_seq: client.seq, operator_seq: operator.seq, scope: "read")
      end

      # Single use: only the first UPDATE ... WHERE used_at IS NULL changes a row.
      def claim(dataset, column, value)
        now = Clock.now
        dataset.where(column => value, used_at: nil).where { expires_at > now }
               .returning.update(used_at: now).first
      end

      def pkce_ok?(row, verifier)
        return true if row[:code_challenge].nil?
        return false if verifier.nil? || row[:code_challenge_method] != "S256"

        expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        Rack::Utils.secure_compare(expected, row[:code_challenge])
      end

      def issue_tokens(grant)
        now = Clock.now
        access = random_token
        refresh = random_token
        AccessToken.create(token_digest: digest(access), grant_seq: grant.seq,
                           expires_at: now + Settings.access_token_ttl, created_at: now)
        RefreshToken.create(token_digest: digest(refresh), grant_seq: grant.seq,
                            expires_at: now + Settings.refresh_token_ttl, created_at: now)
        { access_token: access, token_type: "Bearer", expires_in: Settings.access_token_ttl,
          refresh_token: refresh, scope: grant.scope }
      end
    end
  end

  # Client registration: the client secret is returned once and stored only as a
  # SHA-256 digest; the signing secret is stored as given (research R4).
  module Clients
    module_function

    def register!(name:, redirect_uris:, subscriber_url: nil, rate_limit_per_minute: nil)
      secret = SecureRandom.urlsafe_base64(32)
      client = Client.create(name: name, redirect_uris: Sequel.pg_array(Array(redirect_uris), :text),
                             subscriber_url: subscriber_url, rate_limit_per_minute: rate_limit_per_minute,
                             secret_digest: OAuth::Service.digest(secret),
                             signing_secret: "whsec_#{SecureRandom.hex(24)}")
      [client, secret]
    end
  end
end
