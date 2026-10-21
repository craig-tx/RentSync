# frozen_string_literal: true

require "date"
require "socket"

module MockPms
  # Typed, read-only view of the environment. Defaults mirror .env.example.
  module Settings
    module_function

    def admin_token
      ENV.fetch("ADMIN_TOKEN") { raise KeyError, "ADMIN_TOKEN must be set (see .env.example)" }
    end

    def rack_env = ENV.fetch("RACK_ENV", "development")
    def test? = rack_env == "test"

    def database_url
      test? ? ENV.fetch("TEST_DATABASE_URL") : ENV.fetch("DATABASE_URL")
    end

    def redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

    def seed = Integer(ENV.fetch("SEED", 42))

    def seed_anchor_date
      raw = ENV.fetch("SEED_ANCHOR_DATE", "")
      raw.strip.empty? ? Time.now.utc.to_date : Date.iso8601(raw)
    end

    def access_token_ttl = Integer(ENV.fetch("ACCESS_TOKEN_TTL", 300))
    def refresh_token_ttl = Integer(ENV.fetch("REFRESH_TOKEN_TTL", 2_592_000))
    def rate_limit_per_minute = Integer(ENV.fetch("RATE_LIMIT_PER_MINUTE", 60))
    def retry_base_seconds = Float(ENV.fetch("RETRY_BASE_SECONDS", 2))
    def max_attempts = Integer(ENV.fetch("MAX_ATTEMPTS", 8))
    def metrics_flush_interval_s = Float(ENV.fetch("METRICS_FLUSH_INTERVAL_S", 5))

    def service_version = ENV.fetch("SERVICE_VERSION", "dev")
    def deployment_environment = ENV.fetch("DEPLOYMENT_ENVIRONMENT", "local")
    def service_instance_id = ENV["HOSTNAME"] || Socket.gethostname
  end
end
