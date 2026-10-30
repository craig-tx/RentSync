# frozen_string_literal: true

require "digest"
require "securerandom"

module Rentsync
  module Reconciliation
    # One reconciliation of one connection (research R4, R5): walks /v1/payments since the
    # watermark minus the overlap, or everything on the first run, and records each payment and
    # reversal once. The cursor is saved with each page, so a killed run resumes where it stopped.
    class Run
      include Logging::Loggable

      PAGE_LIMIT = 200
      BACKOFF_BASE_S = 30
      LEASE_S = 300

      # 30 s doubling up to the interval, with equal jitter: half fixed, half random.
      def self.backoff_s(failures, random)
        delay = [BACKOFF_BASE_S * (2**(failures - 1)), Settings.reconcile_interval_s].min
        (delay / 2.0) + (random * delay / 2.0)
      end

      def initialize(connection, client: nil, random: -> { rand })
        @connection = connection
        @client = client || Pms::Client.new(connection)
        @random = random
      end

      # Records the run in reconciliation_runs and returns its row.
      def perform!(trigger:)
        close_interrupted!
        @run_id = start!(trigger)
        walk!
        succeed!
      rescue StandardError => e
        fail!(e)
      ensure
        @run_id && Metrics.increment("rentsync_reconciliation_runs_total", result: run_row[:outcome] || "interrupted")
      end

      private

      def runs = Rentsync.db[:reconciliation_runs]
      def run_row = runs.first(id: @run_id)
      def connections = PmsConnection.where(id: @connection.id)

      # A run still open here was killed: whoever held the lease before us is gone.
      def close_interrupted!
        runs.where(connection_id: @connection.id, outcome: nil)
            .update(outcome: "failed", error_code: "interrupted", finished_at: Clock.now)
      end

      def start!(trigger)
        watermark = @connection.reconcile_watermark
        @window_from = watermark && (watermark - Settings.reconcile_overlap_s)
        @started_at = Clock.now
        @correlation_id = "recon-#{SecureRandom.uuid}"
        runs.insert(connection_id: @connection.id, trigger: watermark ? trigger : "initial", started_at: @started_at,
                    window_from: @window_from, correlation_id: @correlation_id)
      end

      def walk!
        cursor = @connection.reconcile_cursor
        loop do
          params = { limit: PAGE_LIMIT }
          params[:updated_since] = @window_from.utc.iso8601 if @window_from
          params[:cursor] = cursor if cursor
          page = @client.get("/v1/payments", params)
          cursor = page["next_cursor"]
          record_page!(page.fetch("data"), cursor)
          break unless cursor
        end
      end

      # A page's facts, the cursor and the counters commit together; the lease is extended only
      # while this run is still the open one.
      def record_page!(payments, cursor)
        added = Rentsync.db.transaction do
          count = payments.sum { |payment| facts(payment).count { |fact| insert!(fact) } }
          connections.update(reconcile_cursor: cursor, reconcile_lease_until: Clock.now + LEASE_S)
          runs.where(id: @run_id, outcome: nil).update(
            pages: Sequel[:pages] + 1, payments_seen: Sequel[:payments_seen] + payments.size,
            facts_added: Sequel[:facts_added] + count
          )
          count
        end
        log.info("reconciliation page", connection_id: @connection.public_id, payments: payments.size, added: added)
      end

      # payment.created at the payment's received_at (as the PMS's own event), and
      # payment.reversed at reversal.reversed_at when the payment is reversed (research R4).
      def facts(payment)
        id = payment.fetch("id")
        list = [["payment.created", id, payment.fetch("received_at")]]
        list << ["payment.reversed", id, payment.dig("reversal", "reversed_at")] if payment["status"] == "reversed"
        list.map do |type, pay_id, at|
          { type: type, pay_id: pay_id, occurred_at: Time.iso8601(at).utc, payment: payment }
        end
      end

      def insert!(fact)
        bytes = JSON.generate(fact[:payment])
        inserted = Rentsync.db[:raw_events].insert_conflict.returning(:id).insert(
          pms_client_id: @connection.pms_client_id, connection_id: @connection.id,
          event_id: "recon:#{fact[:type]}:#{fact[:pay_id]}", business_key: "#{fact[:type]}:#{fact[:pay_id]}",
          event_type: fact[:type], occurred_at: fact[:occurred_at], received_at: Clock.now,
          arrival_path: "reconciliation", payload_raw: Sequel.blob(bytes),
          payload: Sequel.pg_jsonb_wrap(fact[:payment]), payload_sha256: Sequel.blob(Digest::SHA256.digest(bytes)),
          correlation_id: @correlation_id, reconciliation_run_id: @run_id
        ).any?
        Metrics.increment("rentsync_raw_events_total", arrival_path: "reconciliation", type: fact[:type]) if inserted
        inserted
      end

      def succeed!
        now = Clock.now
        con = PmsConnection[@connection.id]
        requested = con.reconcile_requested_at
        again = requested && requested > @started_at
        Rentsync.db.transaction do
          connections.update(
            reconcile_watermark: walk_started_at, reconcile_cursor: nil, reconcile_failures: 0,
            reconcile_lease_until: nil, reconcile_requested_at: again ? requested : nil,
            next_reconcile_at: again ? now : now + Settings.reconcile_interval_s
          )
          finish!(outcome: "succeeded", finished_at: now)
        end
        run_row
      end

      # The earliest start since the last success: a resumed walk covers pages read before an
      # interruption, so updates made since then must still fall inside the next window.
      def walk_started_at
        since = runs.where(connection_id: @connection.id, outcome: "succeeded").max(:started_at)
        open = runs.where(connection_id: @connection.id).exclude(id: @run_id)
        open = open.where { started_at > since } if since
        [open.min(:started_at), @started_at].compact.min
      end

      def fail!(error)
        code = error_code(error)
        failures = @connection.reconcile_failures + 1
        connections.update(reconcile_failures: failures, reconcile_lease_until: nil,
                           next_reconcile_at: Clock.now + self.class.backoff_s(failures, @random.call))
        finish!(outcome: "failed", error_code: code, finished_at: Clock.now)
        log.warn("reconciliation failed", connection_id: @connection.public_id, error_code: code,
                                          error: error.class.name)
        run_row
      end

      def finish!(**columns)
        runs.where(id: @run_id).update(rate_limit_waits: @client.rate_limit_waits,
                                       rate_limit_wait_s: @client.rate_limit_wait_s.round(3), **columns)
      end

      def error_code(error)
        case error
        when Pms::Renewal::NeedsReauth then "needs_reauth"
        when Pms::Renewal::Unavailable then "renewal_unavailable"
        when Pms::Client::Unauthorized then "unauthorized"
        when Pms::Client::Failed, Pms::Client::Unavailable then "pms_unavailable"
        else "internal_error"
        end
      end
    end
  end
end
