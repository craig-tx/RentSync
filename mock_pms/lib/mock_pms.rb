# frozen_string_literal: true

require "json"
require "time"

require_relative "../config/settings"
require_relative "mock_pms/clock"
require_relative "mock_pms/central_time"
require_relative "mock_pms/ids"
require_relative "mock_pms/db"
require_relative "mock_pms/redis"

module MockPms
  LIB_FILES = %w[
    logging
    models/base
    models/business
    models/oauth
    models/events
    presenters
    pagination
    oauth/service
    seed/wordlists
    seed/generator
    seed/digest
    metrics
    metrics/buffer
    metrics/flusher
    metrics/exposition
    metrics/delivery_collector
    delivery/signer
    delivery/retry_schedule
    delivery/transport
    events/recorder
    delivery/worker
    scenarios/base
    scenarios/tenant_move_out
    scenarios/nsf_wave
    scenarios/month_end_burst
    events/replayer
    admin/idempotency
    middleware/correlation_id
    middleware/request_metrics
    rate_limit/limiter
    middleware/rate_limiter
    chaos/settings
    chaos/decider
    middleware/chaos_errors
    delivery/malformer
    api/errors
    api/ops
    api/admin_base
    api/oauth
    api/v1
    api/admin
    app
  ].freeze

  # Connects, optionally migrates, then loads the rest of the app (models need a
  # live connection and an existing schema when their classes are defined).
  def self.boot!(migrate: false)
    return if @booted

    Settings.deployment_id # fail fast on an invalid DEPLOYMENT_ID
    ensure_database! if migrate
    connect_db!
    migrate! if migrate
    LIB_FILES.each { |f| require_relative "mock_pms/#{f}" }
    @booted = true
  end
end
