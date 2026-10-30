# frozen_string_literal: true

require "securerandom"

module Rentsync
  module Middleware
    # Takes X-Correlation-Id, else X-Request-Id (or generates one), exposes it to logging
    # and every event created during the request, echoes it back, and writes one
    # access-log line per request.
    class CorrelationId
      # The ID is stored and logged before any authentication, so only a short plain token is kept.
      ACCEPTED = /\A[\w.:-]{1,128}\z/

      def initialize(app)
        @app = app
      end

      def call(env)
        given = env["HTTP_X_CORRELATION_ID"] || env["HTTP_X_REQUEST_ID"]
        id = ACCEPTED.match?(given.to_s) ? given : SecureRandom.uuid
        Thread.current[:correlation_id] = id
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = @app.call(env)
        headers["x-correlation-id"] = id
        access_log(env, status, started)
        [status, headers, body]
      ensure
        Thread.current[:correlation_id] = nil
      end

      private

      def access_log(env, status, started)
        route = RouteLabel.for(env)
        function = env["rentsync.answered_by"] ||
                   "Rentsync::API::#{route[:api]}##{env['REQUEST_METHOD']} #{route[:path]}"
        Logging.for_function(function).info(
          "request",
          "http.request.method" => env["REQUEST_METHOD"],
          "url.path" => route[:path],
          "http.response.status_code" => status,
          "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
        )
      end
    end

    # The bounded route label used by metrics and the access log: the Grape route
    # template when Grape routed the request, otherwise a static prefix fallback.
    # Raw paths (which contain IDs) are never used (001 research R12).
    module RouteLabel
      FALLBACK = { "/v1/" => "/v1/{resource}", "/admin/" => "/admin/{endpoint}",
                   "/webhooks/" => "/webhooks/{source}", "/connections" => "/connections/{page}" }.freeze
      APIS = { "/v1" => "V1", "/admin" => "Admin", "/webhooks" => "Webhooks", "/connections" => "Pages" }.freeze

      module_function

      def for(env)
        path = template(env) || fallback(env["PATH_INFO"].to_s)
        { path: path, api: APIS.find { |prefix, _| path.start_with?(prefix) }&.last || "Ops" }
      end

      def template(env)
        route = env.dig("grape.routing_args", :route_info)
        origin = route&.pattern&.origin
        return nil if origin.nil? || origin.include?("*")

        origin.gsub(/:(\w+)/, '{\1}')
      end

      def fallback(path)
        FALLBACK.find { |prefix, _| path.start_with?(prefix) }&.last ||
          (%w[/healthz /healthz/live /metrics].include?(path) ? path : "unmatched")
      end
    end
  end
end
