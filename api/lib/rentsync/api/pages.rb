# frozen_string_literal: true

module Rentsync
  module API
    # US1's pages and their JSON aliases (contracts/openapi.yaml, research R12): sign-in and
    # sign-out, the connections list, connect, the OAuth callback and disconnect. Every query is
    # scoped by the session's operator (FR-023); state-changing forms need the CSRF token.
    class Pages < Grape::API
      include Errors

      SIGN_IN_ERROR = "Email or password is incorrect."
      RESULTS = {
        "connected" => "Connected. RentSync can now read this PMS account.",
        "access_denied" => "The PMS access was denied, so nothing was connected.",
        "pms_operator_taken" => "That PMS account is already connected to another RentSync account.",
        "different_pms_account" => "This RentSync account is linked to a different PMS account. " \
                                   "Sign in to the PMS as that account to reconnect.",
        "pms_unavailable" => "The PMS could not be reached. Please try again in a few minutes.",
        "disconnected" => "Disconnected. RentSync deleted the stored PMS credentials and kept the events " \
                          "already recorded."
      }.freeze

      helpers do
        def current_session = env["rentsync.session"]

        def operator
          return @operator if defined?(@operator)

          @operator = current_session && Operator[current_session.operator_id]
        end

        def csrf_ok? = Auth::Csrf.valid?(current_session, params[Auth::Csrf::FIELD])

        # Login CSRF: sign-in has no session to hold a token, so a browser post from another site
        # is refused by its Fetch Metadata and Origin headers. Clients sending neither (scripts,
        # bin/connect_operator) are allowed; the password still has to be right.
        def same_site_post?
          site = env["HTTP_SEC_FETCH_SITE"]
          return false if site && !%w[same-origin none].include?(site)

          origin = env["HTTP_ORIGIN"]
          origin.nil? || origin == URI(Settings.app_public_url).then { |u| "#{u.scheme}://#{u.authority}" }
        end

        def wants_json? = env["HTTP_ACCEPT"].to_s.include?("application/json")

        def html(name, title:, code: 200, **locals)
          content_type "text/html; charset=utf-8"
          api_format :txt
          status code
          csrf = current_session && Auth::Csrf.token(current_session)
          Web::Page.render(name, title: title, signed_in: !operator.nil?, csrf: csrf, **locals)
        end

        def message(code, heading, text, link: "/connections", link_text: "Back to connections")
          html("message", title: heading, code: code, heading: heading, text: text, link: link, link_text: link_text)
        end

        def see_other(location)
          redirect location
          status 303 # Grape picks 302 for some requests; the contract says 303
        end

        def forbidden = message(403, "Not allowed", "This form has expired. Go back, reload the page and try again.")

        def not_found = message(404, "Not found", "There is no such connection.")

        def not_registered = message(503, "Not ready", "RentSync is not registered with the PMS yet. Run bin/setup.")

        def connection_json(con)
          { id: con.public_id, pms: con.pms_client.pms_key, pms_operator_name: con.pms_operator_name,
            status: con.status, connected_at: con.connected_at&.utc&.iso8601,
            disconnected_at: con.disconnected_at&.utc&.iso8601 }
        end

        def own_connections = PmsConnection.where(operator_id: operator.id).order(:id).eager(:pms_client).all

        def own_connection(public_id) = PmsConnection.first(operator_id: operator.id, public_id: public_id.to_s)
      end

      get "sign-in" do
        html("sign_in", title: "Sign in", error: nil, email: "")
      end

      post "sign-in" do
        next forbidden unless same_site_post?

        email = params[:email].to_s
        unless Auth::SignInThrottle.allow?(email: email, address: request.ip)
          next message(429, "Too many attempts", "Too many sign-in attempts. Wait a minute and try again.",
                       link: "/sign-in", link_text: "Back to sign in")
        end

        signed_in = Auth::Passwords.authenticate(email, params[:password].to_s)
        next html("sign_in", title: "Sign in", error: SIGN_IN_ERROR, email: email) unless signed_in

        header "set-cookie", Middleware::Session.cookie(Auth::Sessions.create!(signed_in))
        see_other("/connections")
      end

      post "sign-out" do
        next see_other("/sign-in") unless operator
        next forbidden unless csrf_ok?

        Auth::Sessions.revoke!(Rack::Request.new(env).cookies[Middleware::Session::COOKIE])
        header "set-cookie", Middleware::Session.cookie(nil)
        see_other("/sign-in")
      end

      get "connections" do
        next see_other("/sign-in") unless operator

        connections = own_connections
        next({ data: connections.map { |c| connection_json(c) } }) if wants_json?

        result = params[:result]
        notice = result && (RESULTS[result] || "The connection was not made (#{result}).")
        html("connections", title: "Connections", connections: connections, notice: notice)
      end

      post "connections" do
        next see_other("/sign-in") unless operator
        next forbidden unless csrf_ok?

        begin
          see_other(Pms::Connect.new.start!(operator))
        rescue Pms::Connect::NotRegistered
          not_registered
        end
      end

      get "connections/callback" do
        next see_other("/sign-in") unless operator

        begin
          result = Pms::Connect.new.finish!(operator, state: params[:state], code: params[:code],
                                                      error: params[:error])
          see_other("/connections?#{URI.encode_www_form(result: result.error_code || result.outcome)}")
        rescue Pms::Connect::InvalidState
          message(400, "Link expired", "This connection link is invalid, already used or expired. Start again.")
        rescue Pms::Connect::NotRegistered
          not_registered
        end
      end

      post "connections/:id/disconnect" do
        next see_other("/sign-in") unless operator
        next forbidden unless csrf_ok?

        con = own_connection(params[:id])
        next not_found unless con

        con.this.update(status: "disconnected", access_token: nil, refresh_token: nil, access_expires_at: nil,
                        renewal_lease_until: nil, disconnected_at: Clock.now)
        Logging.for_function("Rentsync::API::Pages#disconnect").info("connection disconnected",
                                                                     connection_id: con.public_id)
        see_other("/connections?result=disconnected")
      end

      get "v1/connections" do
        api_error!("unauthenticated", "sign in first", 401) unless operator

        { data: own_connections.map { |c| connection_json(c) } }
      end
    end
  end

  App.middlewares << Middleware::Session
  App.apis << API::Pages
end
