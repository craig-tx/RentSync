# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:worker_heartbeats) do
      String :worker_id, text: true, primary_key: true
      column :beat_at, :timestamptz, null: false # updated every 5 s
    end

    # Kept across /admin/reset so a retried reset finds its own key (research R11).
    create_table(:admin_idempotency_keys) do
      String :key, text: true, primary_key: true
      String :request_digest, text: true, null: false # SHA-256 of method, path and body
      column :response_status, :smallint, null: true # null while in flight
      column :response_body, :jsonb, null: true # null while in flight; never secrets
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()") # >24 h may be deleted
    end
  end
end
