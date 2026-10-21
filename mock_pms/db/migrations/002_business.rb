# frozen_string_literal: true

# Business data (data-model.md). Every table except payment_applications has seq,
# id, created_at and updated_at; every foreign key is NOT NULL.
Sequel.migration do
  up do
    identity = lambda do |t, _prefix_comment|
      t.column :seq, :bigint, primary_key: true, identity: :always
      t.String :id, text: true, null: false, unique: true # public id, prefix #{prefix_comment}
    end
    stamps = lambda do |t|
      t.column :created_at, :timestamptz, null: false
      t.column :updated_at, :timestamptz, null: false
    end

    create_table(:operators) do
      identity.call(self, "op_")
      String :name, text: true, null: false
      String :login, text: true, null: false, unique: true
      String :password_digest, text: true, null: false
      String :timezone, text: true, null: false, default: "America/Chicago"
      stamps.call(self)
    end

    create_table(:properties) do
      identity.call(self, "prop_")
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false, index: true
      String :address_line1, text: true, null: false
      String :city, text: true, null: false
      String :state, text: true, null: false
      String :postal_code, text: true, null: false
      column :bedrooms, :smallint
      column :bathrooms, "numeric(3,1)"
      String :status, text: true, null: false
      constraint(:properties_status_check, status: %w[occupied vacant make_ready])
      stamps.call(self)
    end

    create_table(:tenants) do
      identity.call(self, "ten_")
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false, index: true
      String :first_name, text: true, null: false
      String :last_name, text: true, null: false
      String :email, text: true
      String :phone, text: true
      String :status, text: true, null: false
      constraint(:tenants_status_check, status: %w[current former])
      stamps.call(self)
    end

    create_table(:leases) do
      identity.call(self, "lease_")
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false, index: true
      foreign_key :property_seq, :properties, key: :seq, type: :bigint, null: false, index: true
      foreign_key :tenant_seq, :tenants, key: :seq, type: :bigint, null: false, index: true
      Date :start_date, null: false
      Date :scheduled_end_date, null: false
      Date :actual_end_date, null: true
      Integer :monthly_rent_cents, null: false
      String :currency, fixed: true, size: 3, null: false, default: "USD"
      column :due_day, :smallint, null: false
      column :grace_days, :smallint, null: false, default: 3
      Integer :late_fee_cents, null: false, default: 7500
      String :status, text: true, null: false
      constraint(:leases_dates_check) { scheduled_end_date > start_date }
      constraint(:leases_actual_end_check) { (actual_end_date =~ nil) | (actual_end_date <= scheduled_end_date) }
      constraint(:leases_rent_check) { monthly_rent_cents > 0 }
      constraint(:leases_due_day_check, due_day: 1..28)
      constraint(:leases_status_check, status: %w[pending active ended ended_early])
      stamps.call(self)
    end
    # At most one lease per property may be active at a time.
    run "CREATE UNIQUE INDEX leases_one_active_per_property ON leases (property_seq) WHERE status = 'active'"

    create_table(:charges) do
      identity.call(self, "chg_")
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false, index: true
      foreign_key :lease_seq, :leases, key: :seq, type: :bigint, null: false, index: true
      String :kind, text: true, null: false
      Date :period, null: false # first day of the month the charge covers
      Date :due_date, null: false
      Integer :amount_cents, null: false
      String :currency, fixed: true, size: 3, null: false, default: "USD"
      constraint(:charges_kind_check, kind: %w[rent late_fee])
      constraint(:charges_amount_check) { amount_cents > 0 }
      unique %i[lease_seq kind period]
      stamps.call(self)
    end

    create_table(:payments) do
      identity.call(self, "pay_")
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false, index: true
      foreign_key :lease_seq, :leases, key: :seq, type: :bigint, null: false, index: true
      Integer :amount_cents, null: false
      String :currency, fixed: true, size: 3, null: false, default: "USD"
      column :received_at, :timestamptz, null: false
      String :method, text: true, null: false
      String :status, text: true, null: false
      constraint(:payments_amount_check) { amount_cents > 0 }
      constraint(:payments_method_check, method: %w[ach card check money_order])
      constraint(:payments_status_check, status: %w[settled reversed])
      stamps.call(self)
    end

    create_table(:payment_applications) do
      foreign_key :payment_seq, :payments, key: :seq, type: :bigint, null: false
      foreign_key :charge_seq, :charges, key: :seq, type: :bigint, null: false, index: true
      Integer :amount_cents, null: false
      constraint(:payment_applications_amount_check) { amount_cents > 0 }
      primary_key %i[payment_seq charge_seq]
    end

    create_table(:reversals) do
      identity.call(self, "rev_")
      foreign_key :payment_seq, :payments, key: :seq, type: :bigint, null: false, unique: true
      String :reason, text: true, null: false
      column :reversed_at, :timestamptz, null: false
      Integer :amount_cents, null: false
      constraint(:reversals_reason_check, reason: %w[nsf account_closed stop_payment])
      stamps.call(self)
    end
  end

  down do
    drop_table(:reversals, :payment_applications, :payments, :charges, :leases, :tenants, :properties, :operators)
  end
end
