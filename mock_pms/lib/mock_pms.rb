# frozen_string_literal: true

require "json"
require "time"

require_relative "../config/settings"
require_relative "mock_pms/clock"
require_relative "mock_pms/ids"
require_relative "mock_pms/db"
require_relative "mock_pms/redis"

module MockPms
  LIB_FILES = %w[
    logging
    metrics
    metrics/buffer
    metrics/flusher
    metrics/exposition
    admin/idempotency
    middleware/correlation_id
    middleware/request_metrics
    api/errors
    api/ops
    api/admin_base
    app
  ].freeze

  # Connects, optionally migrates, then loads the rest of the app (models need a
  # live connection and an existing schema when their classes are defined).
  def self.boot!(migrate: false)
    return if @booted

    connect_db!
    migrate! if migrate
    LIB_FILES.each { |f| require_relative "mock_pms/#{f}" }
    @booted = true
  end
end
