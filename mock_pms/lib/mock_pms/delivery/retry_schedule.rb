# frozen_string_literal: true

module MockPms
  # The Delivery Sequel model (models/events.rb) doubles as this namespace.
  class Delivery
    # Exponential backoff for failed deliveries: attempt n waits base * 2^(n-1), ±10%
    # jitter; nil after max_attempts means the delivery is exhausted (research R6).
    class RetrySchedule
      def initialize(base: Settings.retry_base_seconds, max_attempts: Settings.max_attempts,
                     jitter: -> { (rand * 0.2) - 0.1 })
        @base = base
        @max_attempts = max_attempts
        @jitter = jitter
      end

      attr_reader :max_attempts

      def next_delay(attempt_number)
        return nil if attempt_number >= @max_attempts

        delay = @base * (2**(attempt_number - 1))
        delay * (1 + @jitter.call)
      end
    end
  end
end
