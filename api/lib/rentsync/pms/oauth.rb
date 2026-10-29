# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "uri"

module Rentsync
  module Pms
    # Where the PMS sends the operator back; registered with the PMS (Registration) and sent on
    # every authorize and code exchange, which the PMS compares exactly.
    def self.redirect_uri = "#{Settings.app_public_url}/connections/callback"

    # The PMS's OAuth endpoints for one registered client (research R7): the authorize URL with
    # a PKCE S256 challenge, the code exchange and the refresh grant. Errors carry the OAuth
    # error code or the HTTP status, never a token or a response body.
    class OAuth
      class Error < StandardError; end

      # The PMS refused: code is its OAuth error (invalid_grant, invalid_client, ...).
      class Rejected < Error
        attr_reader :code

        def initialize(code)
          super("the PMS refused the token request: #{code}")
          @code = code
        end
      end

      # A timeout, connection error or 5xx: worth trying again later.
      class Unavailable < Error; end

      TokenSet = Struct.new(:access_token, :refresh_token, :expires_in, :pms_operator_id, :pms_operator_name,
                            keyword_init: true)

      TIMEOUT_S = 10
      NETWORK_ERRORS = [SystemCallError, IOError, SocketError, Net::OpenTimeout, Net::ReadTimeout,
                        OpenSSL::SSL::SSLError].freeze

      class << self
        # request: ->(Net::HTTPRequest, URI) { [status, body] }; specs replace the network here.
        attr_accessor :default_request
      end

      def initialize(client:, request: nil)
        @client = client
        @request = request || self.class.default_request || method(:send_http)
      end

      def authorize_url(state:, code_verifier:)
        query = URI.encode_www_form(response_type: "code", client_id: @client.client_id,
                                    redirect_uri: Pms.redirect_uri, scope: "read", state: state,
                                    code_challenge: self.class.challenge(code_verifier),
                                    code_challenge_method: "S256")
        "#{Settings.pms_public_url}/oauth/authorize?#{query}"
      end

      def exchange_code(code:, code_verifier:)
        token(grant_type: "authorization_code", code: code, code_verifier: code_verifier,
              redirect_uri: Pms.redirect_uri)
      end

      def refresh(refresh_token)
        token(grant_type: "refresh_token", refresh_token: refresh_token)
      end

      def self.challenge(verifier) = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

      private

      def token(form)
        uri = URI("#{Settings.pms_api_url}/oauth/token")
        req = Net::HTTP::Post.new(uri)
        req.basic_auth(@client.client_id, @client.client_secret_plaintext)
        req["Accept"] = "application/json"
        req.set_form_data(form)
        status, body = @request.call(req, uri)
        parse(status, body)
      rescue *NETWORK_ERRORS => e
        raise Unavailable, "POST /oauth/token: #{e.class}"
      end

      def parse(status, body)
        raise Unavailable, "POST /oauth/token: HTTP #{status}" if status >= 500 || status == 429

        json = begin
          JSON.parse(body.to_s)
        rescue JSON::ParserError
          nil
        end
        raise Rejected, (json.is_a?(Hash) && json["error"].is_a?(String) ? json["error"] : "http_#{status}") \
          unless status == 200 && json.is_a?(Hash)

        TokenSet.new(access_token: json.fetch("access_token"), refresh_token: json.fetch("refresh_token"),
                     expires_in: Integer(json.fetch("expires_in")), pms_operator_id: json["operator_id"],
                     pms_operator_name: json["operator_name"])
      rescue KeyError, ArgumentError, TypeError
        raise Rejected, "malformed_token_response"
      end

      def send_http(req, uri)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                  open_timeout: TIMEOUT_S, read_timeout: TIMEOUT_S) do |http|
          http.request(req)
        end
        [res.code.to_i, res.body.to_s]
      end
    end

    # Hands out a usable access token for a connection, renewing it under a lease when under
    # 60 s remain (FR-004, FR-005; data-model.md "Renewal"). One caller claims
    # renewal_lease_until; others wait up to 5 s for it and reread the row. The PMS refusing
    # the refresh (invalid_grant, invalid_client) means needs_reauth; anything temporary means
    # renewal_failing, with the lease held for the backoff so nobody retries early.
    class Renewal
      include Logging::Loggable

      # The connection is not live; the operator must reconnect.
      class NeedsReauth < StandardError; end
      # The PMS could not be reached, or renewal is backing off or busy elsewhere.
      class Unavailable < StandardError; end

      RENEW_BEFORE_S = 60
      LEASE_S = 30
      WAIT_S = 5
      POLL_S = 0.1
      BACKOFF_BASE_S = 5
      BACKOFF_CAP_S = 300
      REAUTH_CODES = %w[invalid_grant invalid_client].freeze

      def self.backoff_s(failures) = [BACKOFF_BASE_S * (2**(failures - 1)), BACKOFF_CAP_S].min

      def initialize(request: nil)
        @request = request
      end

      def access_token!(connection)
        con = connection
        deadline = monotonic + WAIT_S
        loop do
          raise NeedsReauth, "connection #{con.public_id} is #{con.status}" unless live?(con)
          return con.access_token_plaintext if fresh?(con)

          claimed = claim(con)
          return renew(claimed) if claimed

          con = PmsConnection[con.id]
          next if fresh?(con) || !live?(con)
          raise Unavailable, "renewal is backing off" if con.renewal_failures.positive?
          raise Unavailable, "renewal is taking too long elsewhere" if monotonic > deadline

          sleep POLL_S
        end
      end

      private

      def live?(con) = PmsConnection::LIVE.include?(con.status)

      def fresh?(con) = con.access_expires_at && con.access_expires_at >= Clock.now + RENEW_BEFORE_S

      # Takes the lease only if nobody holds it and the token still needs renewing.
      def claim(con)
        now = Clock.now
        renew_by = now + RENEW_BEFORE_S
        row = PmsConnection.where(id: con.id, status: PmsConnection::LIVE)
                           .where(Sequel.|({ renewal_lease_until: nil }, Sequel[:renewal_lease_until] < now))
                           .where(Sequel.|({ access_expires_at: nil }, Sequel[:access_expires_at] < renew_by))
                           .returning.update(renewal_lease_until: now + LEASE_S).first
        row && PmsConnection.call(row)
      end

      def renew(con)
        tokens = OAuth.new(client: con.pms_client, request: @request).refresh(con.refresh_token_plaintext)
        store(con, tokens)
        log.info("token_renewed", connection_id: con.public_id)
        tokens.access_token
      rescue OAuth::Rejected => e
        return needs_reauth(con, e.code) if REAUTH_CODES.include?(e.code)

        failed(con, e.code, e)
      rescue OAuth::Unavailable => e
        failed(con, "unavailable", e)
      end

      # The new pair, the expiry, the status and the cleared lease in one statement.
      def store(con, tokens)
        changed = PmsConnection.where(id: con.id, status: PmsConnection::LIVE).update(
          con.seal(access_token: tokens.access_token, refresh_token: tokens.refresh_token).merge(
            access_expires_at: Clock.now + tokens.expires_in, status: "active", renewal_failures: 0,
            last_renewal_error: nil, renewal_lease_until: nil
          )
        )
        raise NeedsReauth, "connection #{con.public_id} was disconnected during renewal" if changed.zero?
      end

      def needs_reauth(con, code)
        PmsConnection.where(id: con.id, status: PmsConnection::LIVE)
                     .update(status: "needs_reauth", last_renewal_error: code, renewal_lease_until: nil)
        log.warn("connection needs reauthorization", connection_id: con.public_id, error_code: code)
        raise NeedsReauth, "the PMS refused renewal: #{code}"
      end

      def failed(con, code, error)
        failures = con.renewal_failures + 1
        PmsConnection.where(id: con.id, status: PmsConnection::LIVE).update(
          status: "renewal_failing", renewal_failures: failures, last_renewal_error: code,
          renewal_lease_until: Clock.now + self.class.backoff_s(failures)
        )
        log.warn("token renewal failed", connection_id: con.public_id, error: error.message, failures: failures)
        raise Unavailable, error.message
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
