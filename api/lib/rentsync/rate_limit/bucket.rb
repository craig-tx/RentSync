# frozen_string_literal: true

module Rentsync
  # Token buckets shared by every instance: the state lives in Redis and one Lua script (the
  # mock's, copied) reads, refills, takes and writes it atomically (Constitution X).
  module RateLimit
    WINDOW_MS = 60_000
    SCRIPT = File.expand_path("token_bucket.lua", __dir__)

    module Bucket
      module_function

      # Takes one token from the bucket named by parts; capacity is per minute.
      # Returns { allowed:, retry_after_ms:, remaining: }.
      def take(*parts, capacity:)
        allowed, retry_after_ms, remaining = Rentsync::Redis.evalsha(
          :token_bucket, keys: [Rentsync::Redis.key("rl", *parts)], argv: [capacity, WINDOW_MS, ""]
        )
        { allowed: allowed == 1, retry_after_ms: retry_after_ms, remaining: remaining }
      end
    end

    Rentsync::Redis.load_script(:token_bucket, SCRIPT)
  end
end
