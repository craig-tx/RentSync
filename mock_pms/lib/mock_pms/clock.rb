# frozen_string_literal: true

module MockPms
  # The only source of "now" in domain code, so tests can freeze and advance time.
  module Clock
    class << self
      attr_writer :override

      def now
        value = @override ? @override.call : Time.now
        value.utc
      end

      def today = now.to_date

      def with(fixed_or_proc)
        previous = @override
        @override = fixed_or_proc.respond_to?(:call) ? fixed_or_proc : -> { fixed_or_proc }
        yield
      ensure
        @override = previous
      end
    end
  end
end
