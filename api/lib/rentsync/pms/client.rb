# frozen_string_literal: true

require "net/http"
require "uri"

module Rentsync
  module Pms
    # Calls the PMS API for one connection, politely (research R6): every call takes a token from
    # a Redis bucket shared by all instances and keyed on the PMS client; a 429 blocks every
    # instance until its Retry-After; 429s, 5xx and timeouts are retried with full-jitter
    # backoff. Without Redis it waits rather than calling unmetered (fail closed).
    class Client
      include Logging::Loggable

      # Gave up after MAX_ATTEMPTS; status is the last HTTP status, or nil for a timeout.
      class Failed < StandardError
        attr_reader :status

        def initialize(status)
          @status = status
          super("the PMS kept failing (last status #{status || 'timeout'})")
        end
      end

      # Redis, and so the shared rate limit, was unreachable throughout.
      class Unavailable < StandardError; end
      # A renewed token was refused too.
      class Unauthorized < StandardError; end

      MAX_ATTEMPTS = 6
      BACKOFF_BASE_S = 1
      BACKOFF_CAP_S = 60
      RETRYABLE = [429, 500, 502, 503, 504].freeze

      attr_reader :rate_limit_waits, :rate_limit_wait_s

      # Full jitter: a uniform share of base * 2^(n-1), capped.
      def self.backoff_s(attempt, random) = random * [BACKOFF_BASE_S * (2**(attempt - 1)), BACKOFF_CAP_S].min

      def self.block_key(client_id) = Rentsync::Redis.key("pms", client_id, "blocked_until")

      # Blocks every instance for seconds, keeping a later block already set. Times come from the
      # Redis server's clock, so hosts whose clocks differ agree; now_ms replaces it in specs only.
      def self.block!(client_id, seconds:, now_ms: nil)
        Rentsync::Redis.evalsha(:pms_block_until, keys: [block_key(client_id)],
                                                  argv: [(seconds * 1000).round, now_ms.to_s])
      end

      # Seconds left on the shared block, by the clock that set it; 0 when not blocked.
      def self.blocked_remaining_s(client_id, now_ms: nil)
        Rentsync::Redis.evalsha(:pms_block_remaining, keys: [block_key(client_id)], argv: [now_ms.to_s]) / 1000.0
      end

      def initialize(connection, base_url: Settings.pms_api_url, renewal: Renewal.new,
                     sleeper: ->(s) { sleep s }, random: -> { rand }, read_timeout: 10, clock_ms: nil)
        @connection = connection
        @clock_ms = clock_ms # specs only: replaces Redis's clock for the shared block
        @client_id = connection.pms_client.client_id
        @base_url = base_url.chomp("/")
        @renewal = renewal
        @sleeper = sleeper
        @random = random
        @read_timeout = read_timeout
        @rate_limit_waits = 0
        @rate_limit_wait_s = 0.0
      end

      # GET path with params; returns the parsed JSON body.
      def get(path, params = {})
        reauthorized = false
        attempt = 0
        loop do
          attempt += 1
          meter!(attempt)
          status, headers, body = request(path, params)
          return JSON.parse(body) if status == 200

          if status == 401
            raise Unauthorized, "the PMS refused a renewed token" if reauthorized

            reauthorized = true
            force_renewal!
            attempt -= 1
            next
          end
          raise Failed, status unless status.nil? || RETRYABLE.include?(status)
          raise Failed, status if attempt >= MAX_ATTEMPTS

          retry_after = status == 429 ? Integer(headers["retry-after"].to_s, 10, exception: false).to_i : 0
          self.class.block!(@client_id, seconds: retry_after, now_ms: @clock_ms&.call) if retry_after.positive?
          wait(status == 429, [retry_after, self.class.backoff_s(attempt, @random.call)].max)
        end
      end

      private

      # Waits out any shared block, then for a bucket token. Redis errors count as failed
      # attempts; the PMS is never called without a token.
      def meter!(attempt)
        loop do
          remaining = self.class.blocked_remaining_s(@client_id, now_ms: @clock_ms&.call)
          if remaining.positive?
            wait(true, remaining)
            next
          end
          take = RateLimit::Bucket.take("pms", @client_id, capacity: Settings.pms_rate_limit_per_minute)
          return if take[:allowed]

          wait(true, take[:retry_after_ms] / 1000.0)
        end
      rescue ::Redis::BaseError, SystemCallError => e
        raise Unavailable, "Redis is unreachable: #{e.class.name}" if attempt >= MAX_ATTEMPTS

        log.warn("PMS call waiting for Redis", error: e.class.name)
        @sleeper.call(self.class.backoff_s(attempt, 1.0))
        meter!(attempt + 1)
      end

      def request(path, params)
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) unless params.empty?
        req = Net::HTTP::Get.new(uri, "Accept" => "application/json")
        req["Authorization"] = "Bearer #{@renewal.access_token!(@connection)}"
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = @read_timeout
        http.max_retries = 0 # retries are ours, metered and backed off
        res = http.start { http.request(req) }
        Metrics.increment("rentsync_pms_requests_total", status: res.code)
        [res.code.to_i, res.each_header.to_h, res.body.to_s]
      rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError, IOError
        Metrics.increment("rentsync_pms_requests_total", status: "timeout")
        [nil, {}, ""]
      end

      # A 401 on an unexpired token means the PMS no longer accepts it (a revoked grant):
      # mark it expired so the next call renews, which reports needs_reauth if refused.
      def force_renewal!
        PmsConnection.where(id: @connection.id).update(access_expires_at: Clock.now)
        @connection.refresh
      end

      def wait(rate_limited, seconds)
        if rate_limited
          @rate_limit_waits += 1
          @rate_limit_wait_s += seconds
          Metrics.increment("rentsync_pms_rate_limit_waits_seconds_total", {}, seconds)
        end
        @sleeper.call(seconds)
      end
    end

    Rentsync::Redis.load_script(:pms_block_until, File.expand_path("block_until.lua", __dir__))
    Rentsync::Redis.load_script(:pms_block_remaining, File.expand_path("block_remaining.lua", __dir__))
  end
end
