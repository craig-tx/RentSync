# frozen_string_literal: true

require "socket"

module MockPms
  # The Delivery Sequel model (models/events.rb) doubles as this namespace.
  class Delivery
    # Drains the Postgres outbox (research R6). Claims due deliveries with
    # FOR UPDATE SKIP LOCKED, so any number of workers can run; sends each signed
    # envelope; records an immutable attempt; reschedules or exhausts failures.
    # At-least-once: a crash after sending but before recording means a retry, and
    # the reaper requeues deliveries stuck in_flight.
    class Worker
      include Logging::Loggable

      BATCH = 20
      STALE_AFTER_S = 60
      HEARTBEAT_EVERY_S = 5

      def initialize(transport: Transport.new, schedule: RetrySchedule.new,
                     worker_id: "#{Settings.service_instance_id}-#{Process.pid}")
        @transport = transport
        @schedule = schedule
        @worker_id = worker_id
        @last_beat = nil
      end

      # Returns the number of deliveries attempted.
      def run_once
        now = Clock.now
        heartbeat!(now)
        reap!(now)
        claimed = claim(now)
        claimed.each { |delivery| deliver(delivery) }
        claimed.size
      end

      def reap!(now = Clock.now)
        stale = now - STALE_AFTER_S
        Delivery.where(status: "in_flight").where { updated_at < stale }.update(status: "pending", updated_at: now)
      end

      private

      def heartbeat!(now)
        return if @last_beat && now - @last_beat < HEARTBEAT_EVERY_S

        MockPms.db[:worker_heartbeats]
               .insert_conflict(target: :worker_id, update: { beat_at: Sequel[:excluded][:beat_at] })
               .insert(worker_id: @worker_id, beat_at: now)
        @last_beat = now
      end

      def claim(now)
        MockPms.db.transaction do
          seqs = Delivery.dataset.due(now).limit(BATCH).for_update.skip_locked.select_map(:seq)
          if seqs.empty?
            []
          else
            Delivery.where(seq: seqs).update(status: "in_flight", updated_at: now)
            Delivery.where(seq: seqs).order(:scheduled_at, :seq).eager(:client, event: :operator).all
          end
        end
      end

      def deliver(delivery)
        event = delivery.event
        client = delivery.client
        attempt = delivery.attempt_count + 1
        Thread.current[:correlation_id] = event.correlation_id
        started = Clock.now
        body = body_for(delivery, event)
        headers = headers_for(delivery, attempt: attempt, now: started, body: body)
        result = @transport.post(client.subscriber_url, body: body, headers: headers)
        finished = Clock.now
        record(delivery, attempt, result, started, finished)
        observe(delivery, event, attempt, result, finished - started)
      ensure
        Thread.current[:correlation_id] = nil
      end

      # The bytes to send; chaos (US4) may replace them with a malformed body.
      def body_for(_delivery, event) = Events::Serializer.body(event)

      def headers_for(delivery, attempt:, now:, body:)
        event = delivery.event
        headers = {
          "Content-Type" => "application/json; charset=utf-8",
          "PMS-Event-Id" => event.id,
          "PMS-Event-Type" => event.type,
          "PMS-Delivery-Id" => delivery.id,
          "PMS-Delivery-Attempt" => attempt.to_s,
          "PMS-Signature" => Signer.header(secret: delivery.client.signing_secret, t: now.to_i, body: body),
          "X-Correlation-Id" => event.correlation_id
        }
        headers["PMS-Replay"] = "true" if delivery.replay
        headers
      end

      def record(delivery, attempt, result, started, finished)
        MockPms.db.transaction do
          DeliveryAttempt.create(delivery_seq: delivery.seq, attempt_number: attempt, started_at: started,
                                 finished_at: finished, outcome: result[:outcome], http_status: result[:http_status],
                                 chaos_applied: Sequel.pg_jsonb_wrap(delivery.chaos.to_h),
                                 correlation_id: Thread.current[:correlation_id])
          delivery.update(next_state(attempt, result, finished))
        end
      end

      def next_state(attempt, result, finished)
        return { status: "succeeded", attempt_count: attempt } if result[:outcome] == "success"

        delay = @schedule.next_delay(attempt)
        return { status: "exhausted", attempt_count: attempt } unless delay

        { status: "pending", attempt_count: attempt, scheduled_at: finished + delay }
      end

      def observe(delivery, event, attempt, result, seconds)
        Metrics.observe("mock_pms_delivery_send_duration_seconds", { outcome: result[:outcome] }, seconds)
        log.info("delivery attempt", delivery_id: delivery.id, event_id: event.id, event_type: event.type,
                                     attempt: attempt, outcome: result[:outcome], http_status: result[:http_status],
                                     replay: delivery.replay, chaos: delivery.chaos.to_h,
                                     duration_ms: (seconds * 1000).round(1))
      end
    end
  end
end
