# frozen_string_literal: true

module MockPms
  Operator = Models.define(:operators, prefix: "op") do
    one_to_many :properties, class: "MockPms::Property", key: :operator_seq
    one_to_many :leases, class: "MockPms::Lease", key: :operator_seq
  end

  Property = Models.define(:properties, prefix: "prop") do
    many_to_one :operator, class: "MockPms::Operator", key: :operator_seq
    one_to_many :leases, class: "MockPms::Lease", key: :property_seq
  end

  Tenant = Models.define(:tenants, prefix: "ten") do
    many_to_one :operator, class: "MockPms::Operator", key: :operator_seq
  end

  Lease = Models.define(:leases, prefix: "lease") do
    many_to_one :operator, class: "MockPms::Operator", key: :operator_seq
    many_to_one :property, class: "MockPms::Property", key: :property_seq
    many_to_one :tenant, class: "MockPms::Tenant", key: :tenant_seq
    one_to_many :charges, class: "MockPms::Charge", key: :lease_seq
    one_to_many :payments, class: "MockPms::Payment", key: :lease_seq

    def validate
      super
      if property && property.operator_seq != operator_seq
        errors.add(:operator_seq,
                   "must equal the property's operator")
      end
      return unless actual_end_date && actual_end_date > scheduled_end_date

      errors.add(:actual_end_date, "must be on or before scheduled_end_date")
    end
  end

  Charge = Models.define(:charges, prefix: "chg") do
    many_to_one :lease, class: "MockPms::Lease", key: :lease_seq
    one_to_many :applications, class: "MockPms::PaymentApplication", key: :charge_seq

    def validate
      super
      return unless lease&.actual_end_date && kind == "rent" && period > lease.actual_end_date

      errors.add(:period, "is after the lease's actual_end_date")
    end
  end

  Payment = Models.define(:payments, prefix: "pay") do
    many_to_one :lease, class: "MockPms::Lease", key: :lease_seq
    one_to_many :applications, class: "MockPms::PaymentApplication", key: :payment_seq
    one_to_one :reversal, class: "MockPms::Reversal", key: :payment_seq
  end

  PaymentApplication = Models.define(:payment_applications) do
    unrestrict_primary_key
    many_to_one :payment, class: "MockPms::Payment", key: :payment_seq
    many_to_one :charge, class: "MockPms::Charge", key: :charge_seq

    def validate
      super
      applied = PaymentApplication.where(payment_seq: payment_seq).exclude(charge_seq: charge_seq)
                                  .sum(:amount_cents).to_i
      errors.add(:amount_cents, "exceeds the payment") if payment && applied + amount_cents > payment.amount_cents
      charged = PaymentApplication.where(charge_seq: charge_seq).exclude(payment_seq: payment_seq)
                                  .where(payment_seq: Payment.where(status: "settled").select(:seq))
                                  .sum(:amount_cents).to_i
      errors.add(:amount_cents, "exceeds the charge") if charge && charged + amount_cents > charge.amount_cents
    end
  end

  Reversal = Models.define(:reversals, prefix: "rev") do
    many_to_one :payment, class: "MockPms::Payment", key: :payment_seq

    def validate
      super
      return unless payment

      errors.add(:reversed_at, "must be after the payment") if reversed_at && reversed_at <= payment.received_at
      errors.add(:amount_cents, "must equal the payment's full amount") if amount_cents != payment.amount_cents
    end
  end
end
