# frozen_string_literal: true

require "bcrypt"
require "erb"
require "uri"

module MockPms
  module API
    # /oauth/authorize (HTML sign-in and approval) and /oauth/token (RFC 6749).
    # Exempt from rate limiting and chaos (FR-022, research R7).
    class OAuth < Grape::API
      include Errors

      TEMPLATE = ERB.new(File.read(File.expand_path("../views/authorize.html.erb", __dir__)), trim_mode: "-")
      PASSTHROUGH = %w[response_type client_id redirect_uri state code_challenge code_challenge_method].freeze

      # Renders the template with only the locals it needs, HTML-escaped via h().
      class Page
        include ERB::Util

        def initialize(client:, fields:, login:, error:)
          @client = client
          @fields = fields
          @login = login
          @error = error
        end

        attr_reader :client, :fields, :login, :error

        def render = TEMPLATE.result(binding)
      end

      helpers do
        def authorize_client!
          client = MockPms::Client.first(id: params[:client_id].to_s)
          valid = client && params[:response_type] == "code" &&
                  client.redirect_uris.to_a.include?(params[:redirect_uri].to_s)
          unless valid
            api_error!("invalid_request", "unknown client, unsupported response_type, or unregistered redirect_uri",
                       400)
          end
          client
        end

        def page(client, error: nil, login: nil)
          content_type "text/html; charset=utf-8"
          api_format :txt
          fields = PASSTHROUGH.to_h { |k| [k, params[k].to_s] }.reject { |_, v| v.empty? }
          Page.new(client: client, fields: fields, login: login, error: error).render
        end

        def redirect_with(uri, query)
          base = URI(uri)
          extra = URI.encode_www_form(query.compact)
          base.query = [base.query, extra].compact.reject(&:empty?).join("&")
          redirect base.to_s
        end

        def token_client!
          id, secret = basic_credentials || [params[:client_id], params[:client_secret]]
          MockPms::OAuth::Service.authenticate_client(id, secret)
        end

        def basic_credentials
          header = headers["authorization"] || headers["Authorization"]
          return nil unless header&.start_with?("Basic ")

          Base64.decode64(header.delete_prefix("Basic ")).split(":", 2)
        end

        def oauth_error!(error)
          headers = { "Cache-Control" => "no-store" }
          headers["WWW-Authenticate"] = %(Basic realm="mock_pms") if error.status == 401
          error!({ error: error.code, error_description: error.message }, error.status, headers)
        end
      end

      namespace :oauth do
        get :authorize do
          page(authorize_client!)
        end

        post :authorize do
          client = authorize_client!
          if params[:decision] == "deny"
            redirect_with(params[:redirect_uri], error: "access_denied", state: params[:state])
          else
            operator = MockPms::Operator.first(login: params[:login].to_s)
            unless operator && BCrypt::Password.new(operator.password_digest) == params[:password].to_s
              status 200
              next page(client, error: "Invalid credentials", login: params[:login])
            end

            code = MockPms::OAuth::Service.approve!(client: client, operator: operator,
                                                    redirect_uri: params[:redirect_uri],
                                                    code_challenge: params[:code_challenge],
                                                    code_challenge_method: params[:code_challenge_method])
            redirect_with(params[:redirect_uri], code: code, state: params[:state])
          end
        end

        post :token do
          status 200
          header "Cache-Control", "no-store"
          begin
            client = token_client!
            case params[:grant_type]
            when "authorization_code"
              MockPms::OAuth::Service.exchange_code!(client: client, code: params[:code].to_s,
                                                     redirect_uri: params[:redirect_uri].to_s,
                                                     code_verifier: params[:code_verifier])
            when "refresh_token"
              MockPms::OAuth::Service.refresh!(client: client, refresh_token: params[:refresh_token].to_s)
            else
              raise MockPms::OAuth::Error.new("unsupported_grant_type", "grant_type not supported")
            end
          rescue MockPms::OAuth::Error => e
            oauth_error!(e)
          end
        end
      end
    end
  end
end
