# frozen_string_literal: true

require "spec_helper"

# T058, research R10 and contracts/openapi.yaml Health: one connection's figures, computed from
# durable rows (raw events, receipts, runs) and scoped to that connection.
RSpec.describe Rentsync::Health::Report do
  let(:now) { Time.utc(2026, 10, 31, 14) }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: now },
      client_secret: "CS", signing_secret: "SS"
    )
  end
  let(:operator) { Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x") }
  let(:connection) do
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
                                   pms_operator_name: "Lone Star Rentals", status: "renewal_failing",
                                   access_expires_at: now + 120, last_renewal_error: "unavailable",
                                   connected_at: now - 86_400, next_reconcile_at: now + 600)
  end
  let(:other) do
    who = Rentsync::Operator.create(email: "bo@example.test", name: "Bo", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: who.id, pms_client_id: pms_client.id, pms_operator_id: "op_2",
                                   pms_operator_name: "Prairie Homes", status: "active")
  end

  def raw_event(con, id, type:, path:, received_at:)
    Rentsync.db[:raw_events].insert(
      pms_client_id: pms_client.id, connection_id: con.id, event_id: id, event_type: type, occurred_at: received_at,
      received_at: received_at, arrival_path: path, payload_raw: Sequel.blob("{}"), payload: Sequel.pg_jsonb_wrap({}),
      payload_sha256: Sequel.blob("x"), correlation_id: "c"
    )
  end

  def receipt(con, outcome, reason: nil, age_s: 60, event_id: "evt_x", event_type: "payment.created")
    Rentsync.db[:webhook_receipts].insert(
      received_at: now - age_s, connection_id: con&.id, operator_id: con&.operator_id, outcome: outcome,
      reason: reason, duplicate_of_path: outcome == "duplicate" ? "webhook" : nil, event_id: event_id,
      event_type: event_type, delivery_id: "dlv_SECRET_HEADER", body_bytes: 10, body_sha256: Sequel.blob("x"),
      correlation_id: "corr"
    )
  end

  def run_row(con, outcome:, started_at:, error_code: nil, facts_added: 0)
    Rentsync.db[:reconciliation_runs].insert(
      connection_id: con.id, trigger: "schedule", started_at: started_at, finished_at: started_at + 5,
      outcome: outcome, error_code: error_code, facts_added: facts_added, correlation_id: "r"
    )
  end

  before do
    freeze_time(now)
    raw_event(connection, "evt_1", type: "payment.created", path: "webhook", received_at: now - 3600)
    raw_event(connection, "evt_2", type: "lease.updated", path: "webhook", received_at: now - 1800)
    raw_event(connection, "recon:payment.reversed:pay_1", type: "payment.reversed", path: "reconciliation",
                                                          received_at: now - 7200)
    raw_event(other, "evt_9", type: "payment.created", path: "webhook", received_at: now - 10)
    2.times { receipt(connection, "recorded") }
    receipt(connection, "duplicate")
    receipt(connection, "duplicate", age_s: 91 * 86_400)
    receipt(connection, "rejected", reason: "malformed_body", age_s: 30, event_id: "evt_m", event_type: nil)
    receipt(connection, "rejected", reason: "malformed_body", age_s: 20)
    receipt(connection, "rejected", reason: "conflicting_duplicate", age_s: 10, event_id: "evt_c")
    receipt(connection, "rejected", reason: "stale_timestamp", age_s: 91 * 86_400)
    receipt(nil, "rejected", reason: "unknown_operator")
    receipt(other, "rejected", reason: "no_active_connection")
    run_row(connection, outcome: "succeeded", started_at: now - 1200, facts_added: 3)
    run_row(connection, outcome: "failed", started_at: now - 300, error_code: "pms_unavailable")
  end

  let(:report) { described_class.new(connection).to_h }

  it "returns exactly the Health schema's fields" do
    expect(report.keys).to eq(%i[connection access_status last_successful_sync_at events_received
                                 duplicates_ignored_90d rejected_90d rejected_by_reason_90d last_reconciliation
                                 recent_rejections])
    expect(report[:connection]).to eq(id: connection.public_id, pms: "mock_pms", pms_operator_name: "Lone Star Rentals",
                                      status: "renewal_failing", connected_at: (now - 86_400).iso8601,
                                      disconnected_at: nil)
    expect(report[:access_status]).to eq(status: "renewal_failing", access_expires_at: (now + 120).iso8601,
                                         last_renewal_error: "unavailable")
  end

  it "counts events received in total, by path and by type, for this connection only" do
    expect(report[:events_received]).to eq(total: 3, webhook: 2, reconciliation: 1,
                                           by_type: { "lease.updated" => 1, "payment.created" => 1,
                                                      "payment.reversed" => 1 })
  end

  it "counts duplicates and rejections over the last 90 days, by reason" do
    expect(report[:duplicates_ignored_90d]).to eq(1)
    expect(report[:rejected_90d]).to eq(3)
    expect(report[:rejected_by_reason_90d]).to eq("conflicting_duplicate" => 1, "malformed_body" => 2)
  end

  it "takes the last successful sync as the later of the newest webhook event and the newest successful run" do
    expect(report[:last_successful_sync_at]).to eq((now - 1200 + 5).iso8601)
    raw_event(connection, "evt_3", type: "lease.updated", path: "webhook", received_at: now - 60)
    expect(described_class.new(connection).to_h[:last_successful_sync_at]).to eq((now - 60).iso8601)
  end

  it "shows the last run, its error, the last success and when the next is due (AC3)" do
    expect(report[:last_reconciliation]).to eq(started_at: (now - 300).iso8601, finished_at: (now - 295).iso8601,
                                               outcome: "failed", facts_added: 0, error_code: "pms_unavailable",
                                               last_succeeded_at: (now - 1195).iso8601,
                                               next_due_at: (now + 600).iso8601)
  end

  it "lists recent rejections newest first, with only time, reason, event type and event ID" do
    expect(report[:recent_rejections]).to eq([
                                               { received_at: (now - 10).iso8601, reason: "conflicting_duplicate",
                                                 event_type: "payment.created", event_id: "evt_c" },
                                               { received_at: (now - 20).iso8601, reason: "malformed_body",
                                                 event_type: "payment.created", event_id: "evt_x" },
                                               { received_at: (now - 30).iso8601, reason: "malformed_body",
                                                 event_type: nil, event_id: "evt_m" }
                                             ])
  end

  it "keeps at most 50 recent rejections" do
    60.times { receipt(connection, "rejected", reason: "malformed_body") }
    expect(described_class.new(connection).to_h[:recent_rejections].size).to eq(50)
  end

  it "never includes unknown_operator receipts, or another connection's" do
    reasons = report[:rejected_by_reason_90d].keys + report[:recent_rejections].map { |r| r[:reason] }
    expect(reasons).not_to include("unknown_operator", "no_active_connection", "stale_timestamp")
    expect(report.to_s).not_to include("dlv_SECRET_HEADER", "corr")
  end

  it "has no last run or sync before anything happened" do
    cy = Rentsync::Operator.create(email: "cy@example.test", name: "Cy", password_digest: "x")
    fresh = Rentsync::PmsConnection.create(operator_id: cy.id, pms_client_id: pms_client.id, pms_operator_id: "op_3",
                                           pms_operator_name: "Bluebonnet", status: "active")
    empty = described_class.new(fresh).to_h
    expect(empty).to include(last_successful_sync_at: nil, last_reconciliation: nil, recent_rejections: [],
                             duplicates_ignored_90d: 0, rejected_90d: 0, rejected_by_reason_90d: {})
    expect(empty[:events_received]).to eq(total: 0, webhook: 0, reconciliation: 0, by_type: {})
  end
end
