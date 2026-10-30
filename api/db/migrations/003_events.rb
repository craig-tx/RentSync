# frozen_string_literal: true

# US2's tables (data-model.md raw_events and webhook_receipts; research R3, R4, R10).
Sequel.migration do
  up do
    # One PMS fact exactly as received. Immutable (Constitution I): the trigger below is the
    # backstop for code that has no update path.
    create_table(:raw_events) do
      primary_key :id, type: :Bignum
      foreign_key :pms_client_id, :pms_clients, type: :Bignum, null: false
      foreign_key :connection_id, :pms_connections, type: :Bignum, null: false
      String :event_id, null: false # PMS event ID, or recon:<type>:<pay_id> (R4)
      String :business_key # payment.created:<pay_id> / payment.reversed:<pay_id>; null for lease events
      String :event_type, null: false
      column :occurred_at, :timestamptz, null: false
      column :received_at, :timestamptz, null: false
      String :arrival_path, null: false
      File :payload_raw, null: false # the exact bytes (FR-013)
      column :payload, :jsonb, null: false # parsed copy for queries; never the source of truth
      File :payload_sha256, null: false
      String :correlation_id, null: false
      # reconciliation_runs arrives with US3, whose migration adds the foreign key.
      Bignum :reconciliation_run_id
      unique %i[pms_client_id event_id]
      index %i[pms_client_id business_key], unique: true, where: Sequel.lit("business_key IS NOT NULL"),
                                            name: :raw_events_business_key
      index %i[connection_id received_at]
      index %i[connection_id occurred_at]
      constraint(:raw_events_event_type_check, Sequel.lit(<<~SQL))
        event_type IN ('payment.created', 'payment.reversed', 'lease.updated', 'tenant.moved_out')
      SQL
      constraint(:raw_events_arrival_path_check, Sequel.lit("arrival_path IN ('webhook', 'reconciliation')"))
    end

    run <<~SQL
      CREATE FUNCTION raw_events_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'raw_events is immutable: % refused', TG_OP;
      END;
      $$;
      CREATE TRIGGER raw_events_immutable BEFORE UPDATE OR DELETE ON raw_events
        FOR EACH ROW EXECUTE FUNCTION raw_events_immutable();
    SQL

    # One row per delivery received, whatever its outcome (R10). Bodies are never stored here.
    create_table(:webhook_receipts) do
      primary_key :id, type: :Bignum
      column :received_at, :timestamptz, null: false
      foreign_key :pms_client_id, :pms_clients, type: :Bignum
      foreign_key :connection_id, :pms_connections, type: :Bignum
      foreign_key :operator_id, :operators, type: :Bignum
      String :delivery_id
      Integer :delivery_attempt
      String :event_id
      String :event_type
      String :outcome, null: false
      String :reason
      String :duplicate_of_path
      foreign_key :raw_event_id, :raw_events, type: :Bignum
      Integer :body_bytes, null: false
      File :body_sha256, null: false
      String :correlation_id, null: false
      index %i[connection_id received_at]
      index %i[operator_id outcome received_at]
      constraint(:webhook_receipts_outcome_check, Sequel.lit("outcome IN ('recorded', 'duplicate', 'rejected')"))
      constraint(:webhook_receipts_reason_check, Sequel.lit(<<~SQL))
        (outcome = 'rejected') = (reason IS NOT NULL) AND (reason IS NULL OR reason IN (
          'missing_signature', 'bad_signature', 'stale_timestamp', 'body_too_large', 'malformed_body',
          'unknown_operator', 'no_active_connection', 'conflicting_duplicate', 'internal_error'))
      SQL
      constraint(:webhook_receipts_duplicate_check, Sequel.lit(<<~SQL))
        (outcome = 'duplicate') = (duplicate_of_path IS NOT NULL) AND
          (duplicate_of_path IS NULL OR duplicate_of_path IN ('webhook', 'reconciliation'))
      SQL
    end
  end

  down do
    drop_table(:webhook_receipts)
    drop_table(:raw_events)
    run "DROP FUNCTION raw_events_immutable()"
  end
end
