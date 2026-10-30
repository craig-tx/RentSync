# frozen_string_literal: true

require "json"
require "time"

require_relative "../config/settings"
require_relative "rentsync/clock"
require_relative "rentsync/central_time"
require_relative "rentsync/ids"
require_relative "rentsync/db"
require_relative "rentsync/redis"

module Rentsync
  # The deployed git SHA (feature 002 FR-028), baked into the image by the Dockerfile.
  VERSION = ENV.fetch("SERVICE_VERSION", "dev")

  # Loaded in order once the database is connected (models need a live connection and an
  # existing schema when their classes are defined). Later phases add their files here.
  LIB_FILES = %w[
    logging
    crypto/box
    metrics
    metrics/buffer
    metrics/flusher
    metrics/exposition
    middleware/correlation_id
    middleware/request_metrics
    middleware/session
    models/base
    models/operator
    models/pms_client
    models/pms_connection
    models/session
    models/connection_attempt
    rate_limit/bucket
    auth/passwords
    auth/sessions
    auth/csrf
    auth/sign_in_throttle
    seed/operators
    pms/admin_api
    pms/oauth
    pms/connect
    pms/registration
    metrics/heartbeat_collector
    api/errors
    api/ops
    worker
    jobs/daily_purge
    app
    webhooks/signature
    webhooks/envelope
    webhooks/recorder
    webhooks/receiver
    web/page
    api/pages
    api/admin
  ].freeze

  # Fails fast on bad configuration, connects, optionally migrates, then loads the rest.
  def self.boot!(migrate: false)
    return if @booted

    Settings.validate!
    ensure_database! if migrate
    connect_db!
    migrate! if migrate
    LIB_FILES.each { |f| require_relative "rentsync/#{f}" }
    @booted = true
  end
end
