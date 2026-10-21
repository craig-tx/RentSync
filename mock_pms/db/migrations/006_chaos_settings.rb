# frozen_string_literal: true

# Chaos settings (one row) and per-stream draw counters (research R7). Separate
# counter rows mean an API draw never waits on a delivery transaction's row lock.
Sequel.migration do
  up do
    create_table(:chaos_settings) do
      column :id, :smallint, primary_key: true
      %i[duplicate_rate out_of_order_rate delay_rate server_error_rate malformed_rate].each do |rate|
        column rate, "numeric(4,3)", null: false, default: 0 # each between 0 and 1; all default to 0
        constraint(:"chaos_#{rate}_range") { (Sequel[rate] >= 0) & (Sequel[rate] <= 1) }
      end
      Integer :delay_min_s, null: false, default: 5
      Integer :delay_max_s, null: false, default: 60
      column :seed, :bigint, null: false, default: 1
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      constraint(:chaos_settings_singleton) { id =~ 1 }
      constraint(:chaos_delay_range) { (delay_min_s >= 0) & (delay_min_s <= delay_max_s) & (delay_max_s <= 3600) }
    end
    self[:chaos_settings].insert(id: 1)

    create_table(:chaos_counters) do
      String :stream, text: true, primary_key: true
      column :value, :bigint, null: false, default: 0
      constraint(:chaos_counters_stream_check, stream: %w[delivery api])
    end
    self[:chaos_counters].multi_insert([{ stream: "delivery", value: 0 }, { stream: "api", value: 0 }])
  end

  down do
    drop_table(:chaos_counters, :chaos_settings)
  end
end
