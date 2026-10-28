# frozen_string_literal: true

module Rentsync
  module Middleware
    # Records request counts and latency into the process-local metrics buffer.
    class RequestMetrics
      def initialize(app)
        @app = app
      end

      def call(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = @app.call(env)
        record(env, status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        [status, headers, body]
      end

      private

      def record(env, status, seconds)
        route = RouteLabel.for(env)[:path]
        method = env["REQUEST_METHOD"]
        Metrics.increment("rentsync_http_requests_total", { route: route, method: method, status: status.to_s })
        Metrics.observe("rentsync_http_request_duration_seconds", { route: route, method: method }, seconds)
      end
    end
  end
end
