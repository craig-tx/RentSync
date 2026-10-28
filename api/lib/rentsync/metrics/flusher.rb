# frozen_string_literal: true

module Rentsync
  module Metrics
    # Swaps the buffer and adds the deltas to Redis hashes in one MULTI.
    # HINCRBY/HINCRBYFLOAT are atomic, so concurrent flushes from any number of
    # processes sum correctly without a distributed lock (001 research R12).
    class Flusher
      include Logging::Loggable

      class << self
        def start!(interval: Settings.metrics_flush_interval_s)
          return @thread if @thread&.alive?

          @thread = Thread.new do
            loop do
              sleep interval
              new(buffer: Metrics.buffer).flush!
            end
          end
        end

        def final_flush!
          new(buffer: Metrics.buffer).flush!
        end
      end

      def initialize(buffer:, client: nil)
        @buffer = buffer
        @client = client
      end

      def flush!
        deltas = @buffer.swap!
        return if deltas[:counters].empty? && deltas[:histograms].empty?

        client.multi do |tx|
          write_counters(tx, deltas[:counters])
          write_histograms(tx, deltas[:histograms])
        end
      rescue ::Redis::BaseError, SystemCallError => e
        @buffer.merge!(deltas) if deltas
        log.warn("metrics flush failed; deltas kept for next flush", error: e.class.name)
      end

      private

      def client = @client || Rentsync::Redis.client

      def key(family) = Rentsync::Redis.key("metrics", family)

      def write_counters(tx, counters)
        counters.each do |family, series|
          series.each { |labels, n| tx.hincrby(key(family), labels, n) }
        end
      end

      def write_histograms(tx, histograms)
        histograms.each do |family, series|
          series.each do |labels, hist|
            hist[:buckets].each_with_index do |n, i|
              next if n.zero?

              tx.hincrby(key("#{family}_bucket"), bucket_field(labels, BUCKETS[i]), n)
            end
            tx.hincrbyfloat(key("#{family}_sum"), labels, hist[:sum])
            tx.hincrby(key("#{family}_count"), labels, hist[:count])
          end
        end
      end

      def bucket_field(labels, le)
        labels.empty? ? "le=#{le}" : "#{labels}|le=#{le}"
      end
    end
  end
end
