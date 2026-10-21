# frozen_string_literal: true

require "openssl"

module MockPms
  module Chaos
    # Counter-based randomness (research R7). Each decision takes the next value of a
    # per-stream counter in the database, then derives uniform numbers from
    # HMAC-SHA256(seed, "<stream>:<counter>:<field>"). Results depend only on
    # (seed, counter, field): the same in any process or thread, and across restarts.
    module Decider
      MALFORM_KINDS = %w[truncate drop_field bad_type].freeze
      REORDER_HOLD = (2..10)

      module_function

      def uniform(seed:, stream:, counter:, field:)
        digest = OpenSSL::HMAC.digest("SHA256", seed.to_s, "#{stream}:#{counter}:#{field}")
        digest.byteslice(0, 8).unpack1("Q>") / (2.0**64)
      end

      # Atomic, inside the caller's transaction; the row lock serializes draws per stream.
      def draw!(stream)
        MockPms.db[:chaos_counters].where(stream: stream.to_s).returning(:value)
               .update(value: Sequel[:value] + 1).first[:value]
      end

      # Pure: the decision for one delivery given a counter value.
      def decide(settings, counter:)
        u = ->(field) { uniform(seed: settings[:seed], stream: "delivery", counter: counter, field: field) }
        chaos = {}
        chaos["duplicate"] = true if u.call("duplicate") < settings[:duplicate_rate]
        if u.call("reorder") < settings[:out_of_order_rate]
          chaos["reorder_hold_s"] = pick(REORDER_HOLD, u.call("reorder_hold"))
        end
        if u.call("delay") < settings[:delay_rate]
          chaos["delayed_s"] = pick(settings[:delay_min_s]..settings[:delay_max_s], u.call("delay_s"))
        end
        chaos.merge(malform(settings, u))
      end

      def malform(settings, u)
        return {} unless u.call("malform") < settings[:malformed_rate]

        { "malform" => MALFORM_KINDS[(u.call("malform_kind") * MALFORM_KINDS.size).floor] }
      end

      def pick(range, value) = range.min + (value * (range.max - range.min + 1)).floor

      # Draws and decides for a new delivery. No draw (no write) when chaos is off.
      def decide_delivery!(settings = Settings.current)
        return {} unless Settings.delivery_chaos?(settings)

        decide(settings, counter: draw!(:delivery))
      end

      # A duplicate copy gets its own malform decision from its own draw.
      def decide_copy!(settings = Settings.current)
        return {} unless settings[:malformed_rate].positive?

        counter = draw!(:delivery)
        malform(settings, ->(f) { uniform(seed: settings[:seed], stream: "delivery", counter: counter, field: f) })
      end

      # API stream: only touches the database when server_error_rate > 0.
      def api_server_error?(settings = Settings.current)
        rate = settings[:server_error_rate]
        return false unless rate.positive?

        uniform(seed: settings[:seed], stream: "api", counter: draw!(:api), field: "server_error") < rate
      end
    end
  end
end
