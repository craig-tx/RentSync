# frozen_string_literal: true

# Operator sessions and connection attempts (US1; specs/003-pms-ingestion/data-model.md).
# Columns holding research R8's AES-GCM envelope are marked "enc".
Sequel.migration do
  change do
    # Research R11: the cookie holds a random token; only its SHA-256 is stored.
    create_table(:sessions) do
      primary_key :id, type: :Bignum
      foreign_key :operator_id, :operators, type: :Bignum, null: false
      File :token_sha256, null: false, unique: true
      File :csrf_secret, null: false
      column :created_at, :timestamptz, null: false
      column :last_seen_at, :timestamptz, null: false
      column :revoked_at, :timestamptz
      index :operator_id
    end

    # Research R7: one try at connecting. Single use, 10 minutes, purged after 7 days.
    create_table(:connection_attempts) do
      primary_key :id, type: :Bignum
      foreign_key :operator_id, :operators, type: :Bignum, null: false
      File :state_sha256, null: false, unique: true
      String :code_verifier, text: true # enc (PKCE)
      column :created_at, :timestamptz, null: false
      column :expires_at, :timestamptz, null: false
      column :used_at, :timestamptz
      String :outcome
      String :error_code
      constraint(:connection_attempts_outcome_check,
                 Sequel.lit("outcome IS NULL OR outcome IN ('connected', 'denied', 'failed', 'expired')"))
      index :created_at
    end
  end
end
