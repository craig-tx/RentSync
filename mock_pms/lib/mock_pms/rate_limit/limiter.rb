# frozen_string_literal: true

module MockPms
  # Exact per-client limits shared by every web instance: the bucket lives in Redis
  # and one Lua script reads, refills, takes and writes it atomically (research R8).
  module RateLimit
    WINDOW_MS = 60_000
    SCRIPT = File.expand_path("token_bucket.lua", __dir__)

    module Limiter
      module_function

      def check(client_id:, capacity:, now_ms: nil)
        allowed, retry_after_ms, remaining = MockPms::Redis.evalsha(
          :token_bucket, keys: [MockPms::Redis.key("rl", client_id)],
                         argv: [capacity, WINDOW_MS, now_ms.to_s]
        )
        { allowed: allowed == 1, retry_after_ms: retry_after_ms, remaining: remaining }
      end
    end

    MockPms::Redis.load_script(:token_bucket, SCRIPT)
  end
end
