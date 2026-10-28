# frozen_string_literal: true

# The shared tables every story uses (specs/003-pms-ingestion/data-model.md). Expand-only:
# later changes add columns or tables, never rename or drop (002 research R9).
# Columns holding research R8's AES-GCM envelope are marked "enc".
Sequel.migration do
  change do
    create_table(:operators) do
      primary_key :id, type: :Bignum
      String :public_id, null: false, unique: true # opr_ + 20 base32
      String :email, null: false
      String :name, null: false
      String :password_digest, null: false # bcrypt (research R11)
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      index Sequel.function(:lower, :email), unique: true, name: :operators_email_lower_key
    end

    # RentSync's registration with one PMS (research R9).
    create_table(:pms_clients) do
      primary_key :id, type: :Bignum
      String :pms_key, null: false # "mock_pms"
      String :base_url, null: false
      String :client_id, null: false
      String :client_secret, text: true # enc
      String :signing_secret, text: true # enc
      column :registered_at, :timestamptz, null: false
      column :superseded_at, :timestamptz
      # Exactly one active registration per PMS.
      index :pms_key, unique: true, where: Sequel.lit("superseded_at IS NULL"), name: :pms_clients_one_active
    end

    # One RentSync operator linked to one PMS operator.
    create_table(:pms_connections) do
      primary_key :id, type: :Bignum
      String :public_id, null: false, unique: true # con_ + 20 base32
      foreign_key :operator_id, :operators, type: :Bignum, null: false
      foreign_key :pms_client_id, :pms_clients, type: :Bignum, null: false
      String :pms_operator_id, null: false
      String :pms_operator_name, null: false
      String :status, null: false
      String :access_token, text: true # enc; null after disconnect
      String :refresh_token, text: true # enc; null after disconnect
      column :access_expires_at, :timestamptz
      column :renewal_lease_until, :timestamptz
      Integer :renewal_failures, null: false, default: 0
      String :last_renewal_error
      column :connected_at, :timestamptz
      column :disconnected_at, :timestamptz
      column :reconcile_watermark, :timestamptz
      String :reconcile_cursor
      column :next_reconcile_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :reconcile_lease_until, :timestamptz
      Integer :reconcile_failures, null: false, default: 0
      unique %i[pms_client_id pms_operator_id]
      unique %i[operator_id pms_client_id]
      constraint(:pms_connections_status_check,
                 Sequel.lit("status IN ('active', 'renewal_failing', 'needs_reauth', 'disconnected')"))
    end

    create_table(:maintenance_leases) do
      String :name, primary_key: true # daily_purge
      column :lease_until, :timestamptz
      column :last_run_at, :timestamptz
    end

    # /healthz reports the newest beat's age (as in the mock, 001 data-model).
    create_table(:worker_heartbeats) do
      String :worker_id, primary_key: true # hostname and PID
      column :beat_at, :timestamptz, null: false
    end
  end
end
