# frozen_string_literal: true

module Rentsync
  module Middleware
    # Resolves the rentsync_session cookie to a live session (research R11) and exposes it as
    # env["rentsync.session"]; the pages decide what a missing session means.
    class Session
      COOKIE = "rentsync_session"

      def initialize(app)
        @app = app
      end

      def call(env)
        token = Rack::Request.new(env).cookies[COOKIE]
        env["rentsync.session"] = Auth::Sessions.find(token) if token
        @app.call(env)
      end

      # The Set-Cookie value: HttpOnly, SameSite=Lax (the OAuth callback is a top-level GET from
      # the PMS), and Secure unless RentSync is served from http://localhost.
      def self.cookie(token, expires: nil)
        Rack::Utils.set_cookie_header(COOKIE, { value: token.to_s, path: "/", httponly: true, secure: secure?,
                                                same_site: :lax, expires: expires,
                                                max_age: (token ? Auth::Sessions::ABSOLUTE_S : 0) }.compact)
      end

      def self.secure? = !Settings.app_public_url.start_with?("http://localhost")
    end
  end
end
