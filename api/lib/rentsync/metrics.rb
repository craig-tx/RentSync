# frozen_string_literal: true

module Rentsync
  # Process-local metric deltas, periodically added to cluster-wide totals in Redis
  # with atomic increments; no distributed lock (Constitution X, 001 research R12).
  module Metrics
    BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10].freeze
    DROPPED = "rentsync_metrics_dropped_total"

    # name => [type, help]. Exposition renders only registered families.
    FAMILIES = {
      "rentsync_http_requests_total" => [:counter, "HTTP requests by route template, method and status."],
      "rentsync_http_request_duration_seconds" => [:histogram, "HTTP request latency by route template."],
      DROPPED => [:counter, "Metric label sets dropped because the buffer cap was reached."]
    }.freeze

    class << self
      def buffer = @buffer ||= Buffer.new

      def increment(family, labels = {}, by = 1) = buffer.increment(family, labels, by)
      def observe(family, labels, value) = buffer.observe(family, labels, value)

      def flush! = Flusher.new(buffer: buffer).flush!

      def reset!
        @buffer = Buffer.new
      end

      def label_string(labels)
        labels.map { |k, v| [k.to_s, v.to_s.tr("|=", "__")] }.sort.map { |k, v| "#{k}=#{v}" }.join("|")
      end

      def parse_labels(string)
        return {} if string.nil? || string.empty?

        string.split("|").to_h { |pair| pair.split("=", 2) }
      end
    end
  end
end
