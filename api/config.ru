# frozen_string_literal: true

require_relative "lib/rentsync"

Rentsync.boot!(migrate: true)
Rentsync::Metrics::Flusher.start!
run Rentsync::App.build
