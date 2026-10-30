# frozen_string_literal: true

module Rentsync
  module Jobs
    # Once a day, whichever worker claims the daily_purge lease deletes short-lived rows past
    # their retention (data-model.md): connection attempts after 7 days and webhook receipts after
    # 90 days. Raw events are never purged.
    class DailyPurge
      include Logging::Loggable

      LEASE = "daily_purge"
      EVERY_S = 86_400
      LEASE_S = 600
      ATTEMPTS_KEEP_S = 7 * 86_400
      RECEIPTS_KEEP_S = 90 * 86_400

      # Returns the rows deleted (0 when the run was not due or another worker has it).
      def run_once
        now = Clock.now
        return 0 unless claim(now)

        attempts = Rentsync.db[:connection_attempts].where { created_at < now - ATTEMPTS_KEEP_S }.delete
        receipts = Rentsync.db[:webhook_receipts].where { received_at < now - RECEIPTS_KEEP_S }.delete
        Rentsync.db[:maintenance_leases].where(name: LEASE).update(last_run_at: now, lease_until: nil)
        log.info("daily purge finished", connection_attempts: attempts, webhook_receipts: receipts)
        attempts + receipts
      end

      private

      # Takes the lease when the last run is a day old and nobody holds it.
      def claim(now)
        leases = Rentsync.db[:maintenance_leases]
        held_until = Sequel[:maintenance_leases][:lease_until]
        last_run = Sequel[:maintenance_leases][:last_run_at]
        due = Sequel.&(Sequel.|({ held_until => nil }, held_until < now),
                       Sequel.|({ last_run => nil }, last_run <= now - EVERY_S))
        leases.returning(:name)
              .insert_conflict(target: :name, update: { lease_until: now + LEASE_S }, update_where: due)
              .insert(name: LEASE, lease_until: now + LEASE_S, last_run_at: nil)
              .any?
      end
    end
  end

  Worker.jobs << Jobs::DailyPurge.new
end
