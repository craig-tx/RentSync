# frozen_string_literal: true

# Single mode, three threads: the API fits beside the mock PMS on a 1 GiB host (research R14).
# The web tier is stateless (Constitution X), so more instances are safe; more processes per
# instance are not needed at this scale.
threads 3, 3

port ENV.fetch("PORT", 4002)

# Final metrics flush on graceful shutdown.
at_exit { Rentsync::Metrics::Flusher.final_flush! if defined?(Rentsync::Metrics::Flusher) }
