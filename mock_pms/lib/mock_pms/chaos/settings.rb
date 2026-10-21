# frozen_string_literal: true

module MockPms
  module Chaos
    class Invalid < StandardError; end

    # The single chaos_settings row, read fresh by every process (FR-023, FR-024).
    module Settings
      RATES = %i[duplicate_rate out_of_order_rate delay_rate server_error_rate malformed_rate].freeze
      FIELDS = (RATES + %i[delay_min_s delay_max_s seed]).freeze
      DEFAULTS = RATES.to_h { |r| [r, 0.0] }.merge(delay_min_s: 5, delay_max_s: 60, seed: 1).freeze

      module_function

      def current
        row = MockPms.db[:chaos_settings].first(id: 1)
        return DEFAULTS.dup unless row

        RATES.to_h { |r| [r, row[r].to_f] }.merge(delay_min_s: row[:delay_min_s], delay_max_s: row[:delay_max_s],
                                                  seed: row[:seed])
      end

      # Replaces the given fields, validates, and resets both draw counters in the same
      # transaction, so a given seed replays the same sequence from here (FR-026).
      def update!(changes)
        merged = current.merge(changes.transform_keys(&:to_sym).slice(*FIELDS))
        validate!(merged)
        MockPms.db.transaction do
          MockPms.db[:chaos_settings].where(id: 1).update(merged.merge(updated_at: Clock.now))
          MockPms.db[:chaos_counters].update(value: 0)
        end
        current
      end

      def validate!(s)
        RATES.each { |r| raise Invalid, "#{r} must be between 0 and 1" unless s[r].to_f.between?(0, 1) }
        min = s[:delay_min_s].to_i
        max = s[:delay_max_s].to_i
        raise Invalid, "require 0 <= delay_min_s <= delay_max_s <= 3600" unless min.between?(0, max) && max <= 3600
      end

      def delivery_chaos?(s)
        %i[duplicate_rate out_of_order_rate delay_rate malformed_rate].any? { |r| s[r].positive? }
      end
    end
  end
end
