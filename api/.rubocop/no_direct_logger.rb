# frozen_string_literal: true

module RuboCop
  module Cop
    module Rentsync
      # Logging MUST go through Rentsync::Logging::Loggable so every line carries
      # service.name and code.function.name (001 research R12). Flags Logger.new and
      # logger.info/warn/error/debug outside lib/rentsync/logging.rb.
      class NoDirectLogger < Base
        MSG = "Log through Rentsync::Logging::Loggable (`log.info`), not a raw Logger."
        LEVELS = %i[debug info warn error fatal].to_set.freeze

        def_node_matcher :logger_new?, "(send (const {nil? cbase} :Logger) :new ...)"
        def_node_matcher :logger_call?, "(send (send nil? :logger) LEVELS ...)"

        def on_send(node)
          return unless logger_new?(node) || logger_call?(node)

          add_offense(node)
        end
      end
    end
  end
end
