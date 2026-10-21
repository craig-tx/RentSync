# frozen_string_literal: true

module MockPms
  module API
    # /healthz (db, redis, worker heartbeat), /healthz/live (process up), /metrics.
    class Ops < Grape::API
      include Errors

      HEARTBEAT_MAX_AGE_S = 30

      get "/healthz" do
        db_ok = begin
          MockPms.db.get(1) == 1
        rescue Sequel::Error
          false
        end
        redis_ok = MockPms::Redis.ping?
        beat = db_ok ? MockPms.db[:worker_heartbeats].max(:beat_at) : nil
        age = beat && (Clock.now - beat).round
        healthy = db_ok && redis_ok && age && age < HEARTBEAT_MAX_AGE_S
        status(healthy ? 200 : 503)
        { status: healthy ? "ok" : "degraded", db: db_ok ? "ok" : "down", redis: redis_ok ? "ok" : "down",
          worker_heartbeat_age_s: age }
      end

      get "/healthz/live" do
        { status: "ok" }
      end

      get "/metrics" do
        content_type Metrics::Exposition::CONTENT_TYPE
        api_format :txt
        Metrics::Exposition.render
      end
    end
  end
end
