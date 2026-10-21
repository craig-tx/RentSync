# frozen_string_literal: true

require_relative "lib/mock_pms"

MockPms.boot!
MockPms::Metrics::Flusher.start!
run MockPms::App.build
