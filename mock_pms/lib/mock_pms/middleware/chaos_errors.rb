# frozen_string_literal: true

module MockPms
  module Middleware
    # Injects 500s into /v1/* only, after the rate limiter so injected failures still
    # count against the limit. OAuth and admin are never affected (research R7).
    class ChaosErrors
      ANSWERED_BY = "MockPms::Middleware::ChaosErrors#call"

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless env["PATH_INFO"].to_s.start_with?("/v1/")
        return @app.call(env) unless Chaos::Decider.api_server_error?

        env["mock_pms.answered_by"] = ANSWERED_BY
        body = JSON.generate(API::Errors.body("chaos_injected", "injected server error (chaos)"))
        [500, { "content-type" => "application/json" }, [body]]
      end
    end
  end
end
