# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Rentsync
  module Pms
    # The mock PMS's admin API, used only to register RentSync (research R9). A real PMS would
    # hand over client credentials out of band instead (bin/pms_client --set).
    class AdminApi
      class Error < StandardError; end

      TIMEOUT_S = 10

      # request: ->(Net::HTTPRequest, URI) { [status, body] }, replaced in specs.
      def initialize(base_url: Settings.pms_api_url, token: Settings.mock_pms_admin_token, request: nil)
        @base = base_url
        @token = token
        @request = request || method(:send_http)
      end

      def client_ids
        list = call(Net::HTTP::Get, "/admin/clients")
        raise Error, "GET /admin/clients: expected a list" unless list.is_a?(Array)

        list.map { |c| c["client_id"] }
      end

      # Returns the registration response, which holds client_secret and signing_secret.
      def create_client(name:, redirect_uris:, subscriber_url:)
        call(Net::HTTP::Post, "/admin/clients",
             { name: name, redirect_uris: redirect_uris, subscriber_url: subscriber_url })
      end

      private

      def call(verb, path, body = nil)
        uri = URI("#{@base}#{path}")
        req = verb.new(uri)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body) if body
        status, text = @request.call(req, uri)
        # The body may hold secrets, so only the status is reported.
        raise Error, "#{verb::METHOD} #{path}: HTTP #{status}" unless status.between?(200, 299)

        JSON.parse(text)
      rescue JSON::ParserError
        raise Error, "#{verb::METHOD} #{path}: the response is not JSON"
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        raise Error, "#{verb::METHOD} #{path}: #{e.class}"
      end

      def send_http(req, uri)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                  open_timeout: TIMEOUT_S, read_timeout: TIMEOUT_S) do |http|
          http.request(req)
        end
        [res.code.to_i, res.body.to_s]
      end
    end
  end
end
