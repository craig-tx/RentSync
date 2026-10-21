# frozen_string_literal: true

# The web tier is stateless: rate-limit buckets and metric totals live in Redis,
# everything durable lives in Postgres. Any worker count is safe (research R8, R12).
threads_count = Integer(ENV.fetch("PUMA_THREADS", 5))
worker_count = Integer(ENV.fetch("WEB_CONCURRENCY", 0))
threads threads_count, threads_count
workers worker_count

bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 4001)}"

flush_metrics = lambda do
  MockPms::Metrics::Flusher.final_flush! if defined?(MockPms::Metrics::Flusher)
end

# Final metrics flush on graceful shutdown: per worker in cluster mode, at exit otherwise.
if worker_count.positive?
  before_worker_shutdown { flush_metrics.call }
else
  at_exit { flush_metrics.call }
end
