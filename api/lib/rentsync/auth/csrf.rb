# frozen_string_literal: true

require "base64"
require "openssl"

module Rentsync
  module Auth
    # Per-session CSRF tokens (research R11): an HMAC of the session's random csrf_secret under
    # RENTSYNC_SESSION_SECRET, so the token is stable for the session and useless in any other.
    module Csrf
      FIELD = "csrf_token"

      module_function

      def token(session)
        mac = OpenSSL::HMAC.digest("SHA256", Settings.session_secret, session.csrf_secret.to_s.b)
        Base64.urlsafe_encode64(mac, padding: false)
      end

      def valid?(session, given)
        return false if session.nil? || given.nil? || given.empty?

        Rack::Utils.secure_compare(token(session), given.to_s)
      end
    end
  end
end
