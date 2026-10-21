# frozen_string_literal: true

module MockPms
  module Scenarios
    # Month-end payment spike (FR-028, SC-008): ceil(share × active leases) tenants pay
    # next month's rent within a short window. Each lease pays its earliest open rent
    # charge from next month on, adding the next period's charge when none is open, so
    # repeat runs move forward instead of double-paying.
    class MonthEndBurst < Base
      scenario_name "month_end_burst"

      private

      def perform
        now = Clock.now
        window = Float(option(:window_s, 120))
        leases = scoped(Lease.where(status: "active")).order(:seq).all
        targets = leases.first((Float(option(:share, 0.8)) * leases.size).ceil)
        step = targets.empty? ? 0 : window / targets.size
        created_charges = 0
        paid = targets.each_with_index.count do |lease, i|
          charge, created = open_charge(lease, now)
          next false unless charge

          created_charges += 1 if created
          pay(lease, charge, now - window + (i * step))
          true
        end
        { "payments_created" => paid, "charges_created" => created_charges }
      end

      def pay(lease, charge, received_at)
        amount = charge.amount_cents - settled_applied(charge)
        payment = Payment.create(operator_seq: lease.operator_seq, lease_seq: lease.seq, amount_cents: amount,
                                 received_at: received_at, method: "ach", status: "settled",
                                 created_at: received_at, updated_at: received_at)
        PaymentApplication.create(payment_seq: payment.seq, charge_seq: charge.seq, amount_cents: amount)
        emit("payment.created", lease.operator_seq, Presenters.payment(payment.refresh), received_at)
      end

      # [charge, created?] for the earliest open rent charge from next month, or nil
      # when the lease's term has no further period.
      def open_charge(lease, now)
        first_period = Date.new(now.year, now.month, 1) >> 1
        rents = Charge.where(lease_seq: lease.seq, kind: "rent").where { period >= first_period }.order(:period).all
        open = rents.find { |c| settled_applied(c) < c.amount_cents }
        return [open, false] if open

        period = rents.empty? ? first_period : rents.last.period >> 1
        return nil if period > lease.scheduled_end_date

        due = Date.new(period.year, period.month, lease.due_day)
        [Charge.create(operator_seq: lease.operator_seq, lease_seq: lease.seq, kind: "rent", period: period,
                       due_date: due, amount_cents: lease.monthly_rent_cents, currency: lease.currency), true]
      end

      def settled_applied(charge)
        PaymentApplication.where(charge_seq: charge.seq)
                          .where(payment_seq: Payment.where(status: "settled").select(:seq))
                          .sum(:amount_cents).to_i
      end
    end
  end
end
