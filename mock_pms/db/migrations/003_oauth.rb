# frozen_string_literal: true

# OAuth (data-model.md). Codes, tokens and client secrets are stored only as
# SHA-256 digests; signing secrets are stored as given (research R3, R4).
Sequel.migration do
  up do
    create_table(:clients) do
      column :seq, :bigint, primary_key: true, identity: :always
      String :id, text: true, null: false, unique: true # client_ prefix; the public client_id
      String :name, text: true, null: false
      String :secret_digest, text: true, null: false # SHA-256 of the client secret
      column :redirect_uris, "text[]", null: false
      String :subscriber_url, text: true, null: true
      String :signing_secret, text: true, null: false # stored as given (R4)
      Integer :rate_limit_per_minute, null: true
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      constraint(:clients_redirect_uris_check, Sequel.lit("cardinality(redirect_uris) >= 1"))
    end

    create_table(:grants) do
      column :seq, :bigint, primary_key: true, identity: :always
      String :id, text: true, null: false, unique: true # grant_ prefix
      foreign_key :client_seq, :clients, key: :seq, type: :bigint, null: false
      foreign_key :operator_seq, :operators, key: :seq, type: :bigint, null: false
      String :scope, text: true, null: false, default: "read"
      column :created_at, :timestamptz, null: false
      column :revoked_at, :timestamptz, null: true
    end
    run "CREATE UNIQUE INDEX grants_one_active ON grants (client_seq, operator_seq) WHERE revoked_at IS NULL"

    create_table(:authorization_codes) do
      String :code_digest, text: true, primary_key: true
      foreign_key :grant_seq, :grants, key: :seq, type: :bigint, null: false
      String :redirect_uri, text: true, null: false
      String :code_challenge, text: true, null: true
      String :code_challenge_method, text: true, null: true
      column :expires_at, :timestamptz, null: false
      column :used_at, :timestamptz, null: true
    end

    create_table(:access_tokens) do
      String :token_digest, text: true, primary_key: true
      foreign_key :grant_seq, :grants, key: :seq, type: :bigint, null: false, index: true
      column :expires_at, :timestamptz, null: false
      column :created_at, :timestamptz, null: false
    end

    create_table(:refresh_tokens) do
      String :token_digest, text: true, primary_key: true
      foreign_key :grant_seq, :grants, key: :seq, type: :bigint, null: false, index: true
      column :expires_at, :timestamptz, null: false
      column :used_at, :timestamptz, null: true
      column :created_at, :timestamptz, null: false
    end
  end

  down do
    drop_table(:refresh_tokens, :access_tokens, :authorization_codes, :grants, :clients)
  end
end
