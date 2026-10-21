# frozen_string_literal: true

module MockPms
  module Scenarios
    # One active tenant moves out mid-lease: the lease ends early, the tenant becomes
    # former, and lease.updated then tenant.moved_out are emitted together.
    class TenantMoveOut < Base
      scenario_name "tenant_move_out"

      private

      def perform
        lease = scoped(Lease.where(status: "active")).order(:seq).first
        return { "leases_ended" => 0 } unless lease

        now = Clock.now
        move_out = [Clock.today, lease.scheduled_end_date].min
        lease.update(status: "ended_early", actual_end_date: move_out)
        lease.tenant.update(status: "former")
        lease.property.update(status: "make_ready")
        lease.refresh
        emit("lease.updated", lease.operator_seq, Presenters.lease(lease), now)
        emit("tenant.moved_out", lease.operator_seq,
             { tenant: Presenters.tenant(lease.tenant.refresh), lease: Presenters.lease(lease),
               move_out_date: move_out.iso8601 }, now)
        { "leases_ended" => 1 }
      end
    end
  end
end
