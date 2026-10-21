# frozen_string_literal: true

module MockPms
  module Metrics
    # Delivery metrics read from the outbox tables, which already hold the true values
    # for every worker (research R12). Registered with the exposition at load time.
    module DeliveryCollector
      module_function

      def call
        db = MockPms.db
        [
          ["mock_pms_deliveries_total", :gauge, "Deliveries by current status.",
           db[:deliveries].group_and_count(:status).map { |r| [{ "status" => r[:status] }, r[:count]] }],
          ["mock_pms_delivery_attempts_total", :counter, "Delivery attempts by outcome.",
           db[:delivery_attempts].group_and_count(:outcome).map { |r| [{ "outcome" => r[:outcome] }, r[:count]] }],
          ["mock_pms_delivery_queue_depth", :gauge, "Deliveries pending or in flight.",
           [[{}, db[:deliveries].where(status: %w[pending in_flight]).count]]],
          ["mock_pms_worker_heartbeat_age_seconds", :gauge, "Seconds since the newest worker heartbeat.",
           heartbeat_age(db)]
        ]
      end

      def heartbeat_age(db)
        beat = db[:worker_heartbeats].max(:beat_at)
        beat ? [[{}, (Clock.now - beat).round(1)]] : []
      end
    end

    Exposition.collectors << DeliveryCollector
  end
end
