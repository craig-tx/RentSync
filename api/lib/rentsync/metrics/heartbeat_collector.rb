# frozen_string_literal: true

module Rentsync
  module Metrics
    # The worker heartbeat's age, read from the database, which holds the true value for every
    # worker. Registered with the exposition at load time.
    module HeartbeatCollector
      module_function

      def call
        beat = Rentsync.db[:worker_heartbeats].max(:beat_at)
        samples = beat ? [[{}, (Clock.now - beat).round(1)]] : []
        [["rentsync_worker_heartbeat_age_seconds", :gauge, "Seconds since the newest worker heartbeat.", samples]]
      end
    end

    Exposition.collectors << HeartbeatCollector
  end
end
