# frozen_string_literal: true

require "socket"
require "uri"

module Rentsync
  # Typed, read-only view of the environment (plan.md "Configuration"). validate! runs at boot
  # and names every problem at once. Messages carry variable names, never values.
  module Settings
    class Error < StandardError; end

    URLS = %w[PMS_PUBLIC_URL PMS_API_URL APP_PUBLIC_URL WEBHOOK_SUBSCRIBER_URL].freeze
    REQUIRED = (%w[RENTSYNC_ENCRYPTION_KEYS RENTSYNC_OPERATOR_SEED_PASSWORD RENTSYNC_SESSION_SECRET] + URLS).freeze
    MIN_LENGTHS = { "RENTSYNC_OPERATOR_SEED_PASSWORD" => 16, "RENTSYNC_SESSION_SECRET" => 32 }.freeze
    INTEGERS = { "RECONCILE_INTERVAL_S" => 900, "RECONCILE_OVERLAP_S" => 3600, "PMS_RATE_LIMIT_PER_MINUTE" => 50,
                 "METRICS_FLUSH_INTERVAL_S" => 5 }.freeze

    # Constitution VI: one long-lived stack instance (e.g. prod-us), not a release.
    DEPLOYMENT_ID_FORMAT = /\A[a-z][a-z0-9-]{1,14}[a-z0-9]\z/

    class << self
      # Where values come from: ENV, or a hash in specs.
      def source = @source || ENV

      def with_source(hash)
        previous = @source
        @source = hash
        yield
      ensure
        @source = previous
      end

      def validate!
        problems = missing + malformed
        raise Error, "invalid configuration (see .env.example): #{problems.join('; ')}" unless problems.empty?
      end

      def rack_env = fetch("RACK_ENV", "development")
      def test? = rack_env == "test"

      def database_url = test? ? required("RENTSYNC_TEST_DATABASE_URL") : required("RENTSYNC_DATABASE_URL")
      def redis_url = fetch("RENTSYNC_REDIS_URL", "redis://localhost:6379/1")

      def encryption_keys = required("RENTSYNC_ENCRYPTION_KEYS")
      def operator_seed_password = required("RENTSYNC_OPERATOR_SEED_PASSWORD")
      def session_secret = required("RENTSYNC_SESSION_SECRET")
      # Only registration with the mock needs it (research R9).
      def mock_pms_admin_token = required("MOCK_PMS_ADMIN_TOKEN")

      def pms_public_url = required("PMS_PUBLIC_URL").chomp("/")
      def pms_api_url = required("PMS_API_URL").chomp("/")
      def app_public_url = required("APP_PUBLIC_URL").chomp("/")
      def webhook_subscriber_url = required("WEBHOOK_SUBSCRIBER_URL")

      def reconcile_interval_s = integer("RECONCILE_INTERVAL_S")
      def reconcile_overlap_s = integer("RECONCILE_OVERLAP_S")
      def pms_rate_limit_per_minute = integer("PMS_RATE_LIMIT_PER_MINUTE")
      def metrics_flush_interval_s = integer("METRICS_FLUSH_INTERVAL_S")

      def service_version = fetch("SERVICE_VERSION", "dev")
      def deployment_environment = fetch("DEPLOYMENT_ENVIRONMENT", "local")
      def service_instance_id = fetch("HOSTNAME", nil) || Socket.gethostname

      def deployment_id
        value = fetch("DEPLOYMENT_ID", "local-dev")
        return value if DEPLOYMENT_ID_FORMAT.match?(value)

        raise ArgumentError, "DEPLOYMENT_ID must match #{DEPLOYMENT_ID_FORMAT.source}"
      end

      private

      def fetch(name, default)
        value = source[name]
        value.nil? || value.strip.empty? ? default : value
      end

      def required(name) = fetch(name, nil) || raise(Error, "#{name} must be set (see .env.example)")

      def integer(name)
        Integer(fetch(name, INTEGERS.fetch(name).to_s), 10)
      rescue ArgumentError
        raise Error, "#{name} must be a whole number"
      end

      def missing
        names = REQUIRED + [test? ? "RENTSYNC_TEST_DATABASE_URL" : "RENTSYNC_DATABASE_URL"]
        names.reject { |n| fetch(n, nil) }.map { |n| "#{n} is not set" }
      end

      def malformed
        problems = URLS.select { |n| fetch(n, nil) && !absolute_url?(fetch(n, nil)) }
                       .map { |n| "#{n} must be an absolute http(s) URL" }
        MIN_LENGTHS.each do |name, min|
          value = fetch(name, nil)
          problems << "#{name} must be at least #{min} characters" if value && value.length < min
        end
        INTEGERS.each_key do |name|
          integer(name)
        rescue Error => e
          problems << e.message
        end
        problems.concat(key_problems)
      end

      def key_problems
        keys = fetch("RENTSYNC_ENCRYPTION_KEYS", nil) or return []
        require_relative "../lib/rentsync/crypto/box"
        Rentsync::Crypto::Box.new(keys)
        []
      rescue Rentsync::Crypto::Box::ConfigError => e
        [e.message]
      end

      def absolute_url?(value)
        uri = URI.parse(value)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
