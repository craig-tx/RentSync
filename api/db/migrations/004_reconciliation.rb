# frozen_string_literal: true

# US3's table (data-model.md reconciliation_runs; research R2, R5).
Sequel.migration do
  change do
    create_table(:reconciliation_runs) do
      primary_key :id, type: :Bignum
      foreign_key :connection_id, :pms_connections, type: :Bignum, null: false
      String :trigger, null: false
      column :started_at, :timestamptz, null: false
      column :finished_at, :timestamptz
      String :outcome # null while running
      column :window_from, :timestamptz # null for a full backfill
      Integer :pages, null: false, default: 0
      Integer :payments_seen, null: false, default: 0
      Integer :facts_added, null: false, default: 0
      Integer :rate_limit_waits, null: false, default: 0
      BigDecimal :rate_limit_wait_s, size: [12, 3], null: false, default: 0
      String :error_code
      String :correlation_id, null: false
      index %i[connection_id started_at]
      constraint(:reconciliation_runs_trigger_check, Sequel.lit("trigger IN ('schedule', 'manual', 'initial')"))
      constraint(:reconciliation_runs_outcome_check,
                 Sequel.lit("outcome IS NULL OR outcome IN ('succeeded', 'failed')"))
    end

    # Promised by migration 003.
    alter_table(:raw_events) do
      add_foreign_key [:reconciliation_run_id], :reconciliation_runs, name: :raw_events_reconciliation_run_id_fkey
    end

    # When an operator pressed "Reconcile now" (FR-020), so the run is named manual and a press
    # during a run is not lost.
    alter_table(:pms_connections) do
      add_column :reconcile_requested_at, :timestamptz
    end
  end
end
