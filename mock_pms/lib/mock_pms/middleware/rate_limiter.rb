# frozen_string_literal: true

module MockPms
  module Middleware
    # Applies each client's limit to /v1/* only (FR-021, FR-022). Invalid or expired
    # tokens pass through untouched so V1 answers 401 without spending a token.
    # Fails closed with 503 when Redis is unreachable (research R8).
    class RateLimiter
      include Logging::Loggable

      ANSWERED_BY = "MockPms::Middleware::RateLimiter#call"

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless env["PATH_INFO"].to_s.start_with?("/v1/")

        status, grant = validate(env)
        return @app.call(env) unless status == :valid

        decision = Limit.for(grant)
        return @app.call(env) if decision[:allowed]

        refuse(env, grant, decision)
      rescue ::Redis::BaseError, SystemCallError => e
        log.error("rate limiter unavailable; failing closed", error: e.class.name)
        env["mock_pms.answered_by"] = ANSWERED_BY
        json(503, "rate_limiter_unavailable", "rate limiter unavailable")
      end

      private

      def validate(env)
        header = env["HTTP_AUTHORIZATION"].to_s
        raw = header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : nil
        result = OAuth::Service.validate_access_token(raw)
        env["mock_pms.token_check"] = result
        result
      end

      def refuse(env, grant, decision)
        env["mock_pms.answered_by"] = ANSWERED_BY
        client_id = Client.where(seq: grant.client_seq).get(:id)
        Metrics.increment("mock_pms_rate_limited_total", { client_id: client_id })
        retry_after = [(decision[:retry_after_ms] / 1000.0).ceil, 1].max
        json(429, "rate_limited", "rate limit exceeded; retry after #{retry_after} s",
             "retry-after" => retry_after.to_s)
      end

      def json(status, code, message, headers = {})
        body = JSON.generate(API::Errors.body(code, message))
        [status, { "content-type" => "application/json" }.merge(headers), [body]]
      end

      # Capacity per client: its own rate_limit_per_minute, else the global default.
      module Limit
        module_function

        def for(grant)
          client = Client.where(seq: grant.client_seq).select(:id, :rate_limit_per_minute).first
          capacity = client[:rate_limit_per_minute] || Settings.rate_limit_per_minute
          RateLimit::Limiter.check(client_id: client[:id], capacity: capacity)
        end
      end
    end
  end
end
