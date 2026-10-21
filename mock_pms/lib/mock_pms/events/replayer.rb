# frozen_string_literal: true

module MockPms
  module Events
    # Redelivers past events (FR-029): new delivery rows with replay = true for the
    # original event, so the id, type, occurred_at and payload are unchanged. Chaos is
    # decided as for any new delivery.
    module Replayer
      class Conflict < StandardError; end

      STAGGER_S = 0.001

      module_function

      def replay_one!(event:, client:)
        raise Conflict, "client has no subscriber_url" unless client.subscriber_url
        unless Grant.active.where(client_seq: client.seq, operator_seq: event.operator_seq).any?
          raise Conflict, "client has no active grant for the event's operator"
        end

        MockPms.db.transaction { Recorder.enqueue(event, client, replay: true).first }
      end

      def replay_range!(client:, from:, to:, types: nil)
        raise Conflict, "client has no subscriber_url" unless client.subscriber_url

        operators = Grant.active.where(client_seq: client.seq).select(:operator_seq)
        raise Conflict, "client has no active grant" if operators.empty?

        events = Event.where(operator_seq: operators).where { (occurred_at >= from) & (occurred_at < to) }
        events = events.where(type: Array(types)) if types && !Array(types).empty?
        now = Clock.now
        MockPms.db.transaction do
          events.order(:occurred_at, :seq).all.each_with_index.map do |event, i|
            Recorder.enqueue(event, client, replay: true, scheduled_at: now + (i * STAGGER_S))
          end.size
        end
      end
    end
  end
end
