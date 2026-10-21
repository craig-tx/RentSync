# frozen_string_literal: true

# Kept across /admin/reset (audit of every seeding, research R5).
Sequel.migration do
  change do
    create_table(:seed_runs) do
      column :seq, :bigint, primary_key: true, identity: :always
      column :seed, :bigint, null: false
      Date :anchor_date, null: false
      String :data_digest, text: true, null: false
      column :ran_at, :timestamptz, null: false
    end
  end
end
