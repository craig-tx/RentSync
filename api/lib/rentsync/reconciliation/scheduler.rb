# frozen_string_literal: true

module Rentsync
  module Reconciliation
    # The worker job (research R2): claims one due connection with UPDATE … FOR UPDATE SKIP
    # LOCKED under a lease, so any number of workers never reconcile one connection twice at
    # once, and a crashed worker's lease simply expires. The run extends the lease per page.
    class Scheduler
      LEASE_S = Run::LEASE_S

      def initialize(runner: ->(connection, trigger) { Run.new(connection).perform!(trigger: trigger) })
        @runner = runner
      end

      # Returns 1 when it reconciled a connection, 0 when none was due.
      def run_once
        connection = claim
        return 0 unless connection

        @runner.call(connection, trigger(connection))
        1
      end

      private

      def claim
        now = Clock.now
        lease = Sequel[:reconcile_lease_until]
        due = PmsConnection.where(status: PmsConnection::LIVE).where { next_reconcile_at <= now }
                           .where(Sequel.|({ lease => nil }, lease < now))
                           .order(:next_reconcile_at).limit(1).for_update.skip_locked.select(:id)
        row = PmsConnection.where(id: due).returning.update(reconcile_lease_until: now + LEASE_S).first
        row && PmsConnection.call(row)
      end

      def trigger(connection)
        return "initial" unless connection.reconcile_watermark

        connection.reconcile_requested_at ? "manual" : "schedule"
      end
    end
  end

  Worker.jobs << Reconciliation::Scheduler.new
end
