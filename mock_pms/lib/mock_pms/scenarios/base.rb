# frozen_string_literal: true

require "securerandom"

module MockPms
  # Named, repeatable scripts that change business data and emit the matching
  # events (FR-028). Each run is one transaction whose run_id is the correlation id
  # of every event it creates.
  module Scenarios
    def self.registry = @registry ||= {}

    def self.register(name, klass)
      registry[name] = klass
    end

    class Base
      include Logging::Loggable

      def self.scenario_name(name = nil)
        return @scenario_name unless name

        @scenario_name = name
        Scenarios.register(name, self)
      end

      def self.run!(**) = new(**).run!

      def initialize(operator_id: nil, **options)
        @operator_id = operator_id
        @options = options
        @events_created = 0
      end

      def run!
        run_id = SecureRandom.uuid
        previous = Thread.current[:correlation_id]
        Thread.current[:correlation_id] = run_id
        counts = MockPms.db.transaction { perform }
        log.info("scenario ran", scenario: self.class.scenario_name, events_created: @events_created, counts: counts)
        { scenario: self.class.scenario_name, run_id: run_id, events_created: @events_created, counts: counts }
      ensure
        Thread.current[:correlation_id] = previous
      end

      private

      def option(name, default) = @options.fetch(name, nil) || default

      def scoped(dataset)
        return dataset unless @operator_id

        dataset.where(operator_seq: Operator.where(id: @operator_id.to_s).select(:seq))
      end

      def emit(type, operator_seq, payload, occurred_at)
        Events::Recorder.record!(type: type, operator_seq: operator_seq, payload: payload, occurred_at: occurred_at,
                                 source: "scenario:#{self.class.scenario_name}")
        @events_created += 1
      end
    end
  end
end
