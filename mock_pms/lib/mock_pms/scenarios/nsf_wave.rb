# frozen_string_literal: true

module MockPms
  module Scenarios
    # Several recent payments bounce: each is reversed in full (reason nsf) and a
    # payment.reversed event is emitted with the reversal filled in.
    class NsfWave < Base
      scenario_name "nsf_wave"

      private

      def perform
        now = Clock.now
        payments = scoped(Payment.where(status: "settled").exclude(seq: Reversal.select(:payment_seq)))
                   .order(Sequel.desc(:received_at), Sequel.desc(:seq)).limit(Integer(option(:count, 5))).all
        payments.each do |payment|
          Reversal.create(payment_seq: payment.seq, reason: "nsf", reversed_at: now, amount_cents: payment.amount_cents)
          payment.update(status: "reversed")
          emit("payment.reversed", payment.operator_seq, Presenters.payment(payment.refresh), now)
        end
        { "payments_reversed" => payments.size }
      end
    end
  end
end
