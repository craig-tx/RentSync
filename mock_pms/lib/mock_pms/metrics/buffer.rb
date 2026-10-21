# frozen_string_literal: true

module MockPms
  module Metrics
    # Mutex-guarded delta buffer. Holds increments since the last flush, never totals.
    # swap! is O(1) so request threads never wait on Redis.
    class Buffer
      DEFAULT_CAP = 10_000

      def initialize(cap: DEFAULT_CAP)
        @cap = cap
        @mutex = Mutex.new
        reset_state
      end

      def increment(family, labels = {}, by = 1)
        key = Metrics.label_string(labels)
        @mutex.synchronize do
          series = (@counters[family] ||= {})
          next drop! unless series.key?(key) || room?

          @fields += 1 unless series.key?(key)
          series[key] = series.fetch(key, 0) + by
        end
      end

      def observe(family, labels, value)
        key = Metrics.label_string(labels)
        @mutex.synchronize do
          series = (@histograms[family] ||= {})
          next drop! unless series.key?(key) || room?

          @fields += 1 unless series.key?(key)
          hist = (series[key] ||= { buckets: Array.new(BUCKETS.size, 0), sum: 0.0, count: 0 })
          index = BUCKETS.index { |le| value <= le }
          hist[:buckets][index] += 1 if index
          hist[:sum] += value
          hist[:count] += 1
        end
      end

      def swap!
        @mutex.synchronize do
          deltas = { counters: @counters, histograms: @histograms }
          deltas[:counters][DROPPED] = { "" => @dropped } if @dropped.positive?
          reset_state
          deltas.transform_values { |families| families.reject { |_, series| series.empty? } }
        end
      end

      # Puts deltas from a failed flush back so the next flush sends them.
      def merge!(deltas)
        deltas[:counters].each do |family, series|
          series.each { |labels, n| merge_counter(family, labels, n) }
        end
        deltas[:histograms].each do |family, series|
          series.each { |labels, hist| merge_histogram(family, labels, hist) }
        end
      end

      private

      def reset_state
        @counters = {}
        @histograms = {}
        @fields = 0
        @dropped = 0
      end

      def room? = @fields < @cap

      def drop!
        @dropped += 1
        nil
      end

      def merge_counter(family, labels, n)
        @mutex.synchronize do
          series = (@counters[family] ||= {})
          @fields += 1 unless series.key?(labels)
          series[labels] = series.fetch(labels, 0) + n
        end
      end

      def merge_histogram(family, labels, hist)
        @mutex.synchronize do
          series = (@histograms[family] ||= {})
          @fields += 1 unless series.key?(labels)
          current = (series[labels] ||= { buckets: Array.new(BUCKETS.size, 0), sum: 0.0, count: 0 })
          current[:buckets] = current[:buckets].zip(hist[:buckets]).map(&:sum)
          current[:sum] += hist[:sum]
          current[:count] += hist[:count]
        end
      end
    end
  end
end
