# frozen_string_literal: true

module Rentsync
  module Health
    # One connection's health (US4, research R10, contracts/openapi.yaml Health): aggregates over
    # raw events, receipts and runs, so the figures are exact across instances and restarts
    # (FR-022). Everything is scoped to the connection; receipts with no connection, such as
    # unknown_operator, appear in no report. Only times, codes, counts and event IDs leave here.
    class Report
      WINDOW_S = 90 * 86_400
      RECENT_LIMIT = 50

      def self.connection_json(con)
        { id: con.public_id, pms: con.pms_client.pms_key, pms_operator_name: con.pms_operator_name,
          status: con.status, connected_at: iso(con.connected_at), disconnected_at: iso(con.disconnected_at) }
      end

      def self.iso(time) = time&.utc&.iso8601

      def initialize(connection)
        @connection = connection
        @since = Clock.now - WINDOW_S
      end

      def to_h
        rejected = rejections_by_reason
        { connection: self.class.connection_json(@connection), access_status: access_status,
          last_successful_sync_at: iso(last_successful_sync), events_received: events_received,
          duplicates_ignored_90d: receipts.where(outcome: "duplicate").count, rejected_90d: rejected.values.sum,
          rejected_by_reason_90d: rejected, last_reconciliation: last_reconciliation,
          recent_rejections: recent_rejections }
      end

      private

      def iso(time) = self.class.iso(time)
      def raw_events = Rentsync.db[:raw_events].where(connection_id: @connection.id)

      def receipts
        Rentsync.db[:webhook_receipts].where(connection_id: @connection.id).where(Sequel[:received_at] >= @since)
      end

      def runs = Rentsync.db[:reconciliation_runs].where(connection_id: @connection.id)

      def access_status
        { status: @connection.status, access_expires_at: iso(@connection.access_expires_at),
          last_renewal_error: @connection.last_renewal_error }
      end

      # The later of the newest event a webhook recorded and the newest successful run.
      def last_successful_sync
        [raw_events.where(arrival_path: "webhook").max(:received_at),
         runs.where(outcome: "succeeded").max(:finished_at)].compact.max
      end

      def events_received
        by_path = raw_events.group_and_count(:arrival_path).to_hash(:arrival_path, :count)
        { total: by_path.values.sum, webhook: by_path.fetch("webhook", 0),
          reconciliation: by_path.fetch("reconciliation", 0),
          by_type: raw_events.group_and_count(:event_type).order(:event_type).to_hash(:event_type, :count) }
      end

      def rejections_by_reason
        receipts.where(outcome: "rejected").group_and_count(:reason).order(:reason).to_hash(:reason, :count)
      end

      def last_reconciliation
        run = runs.order(Sequel.desc(:id)).first
        return nil unless run

        { started_at: iso(run[:started_at]), finished_at: iso(run[:finished_at]), outcome: run[:outcome],
          facts_added: run[:facts_added], error_code: run[:error_code],
          last_succeeded_at: iso(runs.where(outcome: "succeeded").max(:finished_at)),
          next_due_at: iso(@connection.next_reconcile_at) }
      end

      def recent_rejections
        receipts.where(outcome: "rejected").order(Sequel.desc(:received_at), Sequel.desc(:id)).limit(RECENT_LIMIT)
                .select_map(%i[received_at reason event_type event_id])
                .map { |at, reason, type, id| { received_at: iso(at), reason: reason, event_type: type, event_id: id } }
      end
    end
  end
end
