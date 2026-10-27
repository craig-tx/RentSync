# frozen_string_literal: true

module MockPms
  # Formats a time in US Central time for people reading /healthz ("2026-10-27 07:00:05 CDT").
  # The US rule since 2007, written here instead of adding a time zone gem (constitution VIII):
  # daylight time (UTC-5) from 2:00 local on the second Sunday of March to 2:00 local on the
  # first Sunday of November; standard time (UTC-6) otherwise.
  module CentralTime
    STANDARD = -6 * 3600
    DAYLIGHT = -5 * 3600

    class << self
      def format(time)
        utc = time.utc
        offset = daylight?(utc) ? DAYLIGHT : STANDARD
        (utc + offset).strftime("%Y-%m-%d %H:%M:%S ") + (offset == DAYLIGHT ? "CDT" : "CST")
      end

      private

      # Both switches happen at 2:00 local: 08:00 UTC in March (from CST), 07:00 UTC in November
      # (from CDT).
      def daylight?(utc)
        starts = Time.utc(utc.year, 3, nth_sunday(utc.year, 3, 2), 8)
        ends = Time.utc(utc.year, 11, nth_sunday(utc.year, 11, 1), 7)
        utc >= starts && utc < ends
      end

      def nth_sunday(year, month, nth)
        first = Time.utc(year, month, 1)
        1 + ((7 - first.wday) % 7) + (7 * (nth - 1))
      end
    end
  end
end
