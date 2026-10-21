# frozen_string_literal: true

module MockPms
  module Events
    API_VERSION = "2026-10-01"

    # The webhook envelope (contracts/webhooks.md). data.object is the snapshot taken
    # when the event was recorded, in the resource's /v1 shape.
    module Serializer
      module_function

      def envelope(event, operator_id: nil)
        {
          id: event.id, type: event.type, occurred_at: Presenters.time(event.occurred_at),
          operator_id: operator_id || event.operator.id, api_version: API_VERSION,
          data: { object: JSON.parse(JSON.generate(event.payload)) }
        }
      end

      def body(event) = JSON.generate(envelope(event))
    end

    # Records an immutable event and fans it out to the outbox, in the caller's
    # transaction (FR-015 to FR-017): one delivery per client holding an active grant
    # for the event's operator and a subscriber_url.
    module Recorder
      module_function

      def record!(type:, operator_seq:, payload:, occurred_at:, source:, correlation_id: nil)
        MockPms.db.transaction(savepoint: true) do
          event = Event.create(type: type, operator_seq: operator_seq, payload: Sequel.pg_jsonb_wrap(payload),
                               occurred_at: occurred_at, source: source,
                               correlation_id: correlation_id || Thread.current[:correlation_id] || "none")
          subscribers(operator_seq).each { |client| enqueue(event, client) }
          event
        end
      end

      def subscribers(operator_seq)
        Client.where(seq: Grant.active.where(operator_seq: operator_seq).select(:client_seq))
              .exclude(subscriber_url: nil).order(:seq).all
      end

      # One row per planned copy. Chaos (US4) can add a duplicate copy and move
      # scheduled_at; with chaos off it is exactly one immediate delivery.
      def enqueue(event, client, replay: false, scheduled_at: Clock.now)
        chaos_for(event, client).map do |plan|
          Delivery.create(id: plan[:id] || Ids.generate("dlv"), event_seq: event.seq, client_seq: client.seq,
                          replay: replay, status: "pending",
                          scheduled_at: scheduled_at + plan.fetch(:offset_s, 0),
                          chaos: Sequel.pg_jsonb_wrap(plan.fetch(:chaos, {})))
        end
      end

      # The chaos decision is made here, at creation, and stored on each row (research
      # R7): out-of-order and delay move scheduled_at; a duplicate adds a copy that
      # points at the first delivery and gets its own malform decision.
      def chaos_for(_event, _client)
        decision = Chaos::Decider.decide_delivery!
        first_id = Ids.generate("dlv")
        offset = decision.fetch("reorder_hold_s", 0) + decision.fetch("delayed_s", 0)
        plans = [{ id: first_id, chaos: decision.except("duplicate"), offset_s: offset }]
        if decision["duplicate"]
          plans << { chaos: { "duplicate_of" => first_id }.merge(Chaos::Decider.decide_copy!), offset_s: 0 }
        end
        plans
      end
    end
  end
end
