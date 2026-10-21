# frozen_string_literal: true

# Events (immutable), deliveries (the outbox) and delivery_attempts (immutable
# delivery log, FR-020). Research R6, data-model.md.
Sequel.migration do
  up do
    create_table(:events) do
      column :seq, :bigint, primary_key: true, identity: :always
      String :id, text: true, null: false, unique: true # evt_; the idempotency key receivers dedupe on
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false, index: true
      String :type, text: true, null: false
      column :occurred_at, :timestamptz, null: false
      column :payload, :jsonb, null: false
      String :correlation_id, text: true, null: false
      String :source, text: true, null: false # seed, scenario:<name>, or admin
      column :created_at, :timestamptz, null: false
      constraint(:events_type_check, type: %w[payment.created payment.reversed lease.updated tenant.moved_out])
      index :occurred_at
    end

    create_table(:deliveries) do
      column :seq, :bigint, primary_key: true, identity: :always
      String :id, text: true, null: false, unique: true # dlv_
      foreign_key :event_seq, :events, key: :seq, type: :bigint, null: false, index: true
      foreign_key :client_seq, :clients, key: :seq, type: :bigint, null: false, index: true
      column :scheduled_at, :timestamptz, null: false
      String :status, text: true, null: false, default: "pending"
      column :attempt_count, :smallint, null: false, default: 0
      TrueClass :replay, null: false, default: false
      column :chaos, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      constraint(:deliveries_status_check, status: %w[pending in_flight succeeded exhausted])
      index %i[status scheduled_at]
    end

    create_table(:delivery_attempts) do
      column :seq, :bigint, primary_key: true, identity: :always
      foreign_key :delivery_seq, :deliveries, key: :seq, type: :bigint, null: false
      column :attempt_number, :smallint, null: false
      column :started_at, :timestamptz, null: false
      column :finished_at, :timestamptz, null: false
      String :outcome, text: true, null: false
      column :http_status, :smallint, null: true
      column :chaos_applied, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      String :correlation_id, text: true, null: false
      constraint(:delivery_attempts_outcome_check, outcome: %w[success http_error timeout connection_error])
      unique %i[delivery_seq attempt_number]
    end

    # Events and delivery attempts are never updated or deleted (TRUNCATE on reset
    # is unaffected: row triggers do not fire for it).
    run <<~SQL
      CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable', TG_TABLE_NAME;
      END $$;
      CREATE TRIGGER events_immutable BEFORE UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
      CREATE TRIGGER delivery_attempts_immutable BEFORE UPDATE OR DELETE ON delivery_attempts
        FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
    SQL
  end

  down do
    drop_table(:delivery_attempts, :deliveries, :events)
    run "DROP FUNCTION forbid_mutation()"
  end
end
