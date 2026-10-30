# frozen_string_literal: true

require "spec_helper"

# T038, research R3 step 5-6 and R4, data-model.md raw_events and webhook_receipts: one raw event
# per PMS event ID or business key, whichever path saw it first, and one receipt per delivery.
RSpec.describe Rentsync::Webhooks::Recorder do
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end
  let(:operator) { Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x") }
  let!(:connection) { connect(operator, "op_1") }
  let(:now) { Time.utc(2026, 10, 31, 14, 6) }

  before { freeze_time(now) }

  def connect(who, pms_operator_id, status: "active")
    Rentsync::PmsConnection.create(operator_id: who.id, pms_client_id: pms_client.id, pms_operator_id: pms_operator_id,
                                   pms_operator_name: "PMS #{pms_operator_id}", status: status, connected_at: now)
  end

  def body_for(id: "evt_1", type: "payment.created", operator_id: "op_1", object: { "id" => "pay_1", "n" => 1 })
    JSON.generate("id" => id, "type" => type, "occurred_at" => "2026-10-31T14:05:12Z", "operator_id" => operator_id,
                  "api_version" => "2026-10-01", "data" => { "object" => object })
  end

  def delivery(event_id: "evt_1", delivery_id: "dlv_1")
    Rentsync::Webhooks::Delivery.new(delivery_id: delivery_id, attempt: 1, event_id: event_id,
                                     event_type: "payment.created", correlation_id: "corr-1", received_at: now)
  end

  def record(body = body_for, event_id: JSON.parse(body)["id"], delivery_id: "dlv_1")
    envelope = Rentsync::Webhooks::Envelope.parse(body, event_id: event_id)
    described_class.record!(pms_client: pms_client, envelope: envelope, body: body,
                            delivery: delivery(event_id: event_id, delivery_id: delivery_id))
  end

  def raw_events = Rentsync.db[:raw_events]
  def receipts = Rentsync.db[:webhook_receipts]

  it "records a new event: exact bytes, parsed copy, digest, connection and correlation ID" do
    body = body_for
    result = record(body)
    expect(result).to have_attributes(outcome: "recorded", reason: nil)
    row = raw_events.first
    expect(row).to include(id: result.raw_event_id, pms_client_id: pms_client.id, connection_id: connection.id,
                           event_id: "evt_1", business_key: "payment.created:pay_1", event_type: "payment.created",
                           occurred_at: Time.utc(2026, 10, 31, 14, 5, 12), received_at: now,
                           arrival_path: "webhook", correlation_id: "corr-1", reconciliation_run_id: nil)
    expect(row[:payload_raw]).to eq(body.b)
    expect(row[:payload_sha256]).to eq(Digest::SHA256.digest(body))
    expect(JSON.parse(row[:payload].to_json)).to eq(JSON.parse(body))
  end

  it "treats the same event ID and body as a duplicate of the webhook copy" do
    first = record
    again = record(delivery_id: "dlv_2")
    expect(again).to have_attributes(outcome: "duplicate", duplicate_of_path: "webhook",
                                     raw_event_id: first.raw_event_id)
    expect(raw_events.count).to eq(1)
  end

  it "rejects the same event ID with a different body as conflicting_duplicate, keeping the first" do
    first_body = body_for
    record(first_body)
    result = record(body_for(object: { "id" => "pay_1", "n" => 2 }), delivery_id: "dlv_2")
    expect(result).to have_attributes(outcome: "rejected", reason: "conflicting_duplicate",
                                      raw_event_id: raw_events.first[:id])
    expect(raw_events.count).to eq(1)
    expect(raw_events.first[:payload_raw]).to eq(first_body.b)
  end

  it "treats a payment already recorded by reconciliation as a duplicate of that path (R4)" do
    snapshot = JSON.generate("id" => "pay_1", "status" => "settled")
    recon_id = raw_events.insert(
      pms_client_id: pms_client.id, connection_id: connection.id, event_id: "recon:payment.created:pay_1",
      business_key: "payment.created:pay_1", event_type: "payment.created", occurred_at: now, received_at: now,
      arrival_path: "reconciliation", payload_raw: Sequel.blob(snapshot),
      payload: Sequel.pg_jsonb_wrap(JSON.parse(snapshot)),
      payload_sha256: Sequel.blob(Digest::SHA256.digest(snapshot)), correlation_id: "recon-corr"
    )
    result = record
    expect(result).to have_attributes(outcome: "duplicate", duplicate_of_path: "reconciliation",
                                      raw_event_id: recon_id)
    expect(raw_events.count).to eq(1)
    expect(receipts.first).to include(outcome: "duplicate", duplicate_of_path: "reconciliation")
  end

  it "records every lease event, which has no business key" do
    lease = { "id" => "lea_1", "status" => "active" }
    record(body_for(id: "evt_1", type: "lease.updated", object: lease))
    record(body_for(id: "evt_2", type: "lease.updated", object: lease))
    expect(raw_events.select_map(:business_key)).to eq([nil, nil])
  end

  it "rejects an operator never connected as unknown_operator, with no operator on the receipt" do
    result = record(body_for(operator_id: "op_9"))
    expect(result).to have_attributes(outcome: "rejected", reason: "unknown_operator", raw_event_id: nil)
    expect(raw_events.count).to eq(0)
    expect(receipts.first).to include(reason: "unknown_operator", operator_id: nil, connection_id: nil,
                                      pms_client_id: pms_client.id)
  end

  it "rejects a disconnected or needs_reauth connection as no_active_connection, scoped to its operator" do
    %w[disconnected needs_reauth].each do |status|
      connection.this.update(status: status)
      expect(record).to have_attributes(outcome: "rejected", reason: "no_active_connection")
    end
    expect(raw_events.count).to eq(0)
    expect(receipts.select_map(%i[operator_id connection_id]).uniq).to eq([[operator.id, connection.id]])
  end

  it "still accepts events while renewal is failing" do
    connection.this.update(status: "renewal_failing")
    expect(record.outcome).to eq("recorded")
  end

  it "writes exactly one receipt per outcome, with the delivery's details and no body" do
    body = body_for
    record(body)
    record(body, delivery_id: "dlv_2")
    record(body_for(object: { "id" => "pay_1", "n" => 3 }), delivery_id: "dlv_3")
    record(body_for(id: "evt_9", operator_id: "op_9"), delivery_id: "dlv_4")
    rows = receipts.order(:id).all
    expect(rows.map { |r| [r[:delivery_id], r[:outcome], r[:reason]] })
      .to eq([%w[dlv_1 recorded] + [nil], %w[dlv_2 duplicate] + [nil], %w[dlv_3 rejected conflicting_duplicate],
              %w[dlv_4 rejected unknown_operator]])
    expect(rows.first).to include(received_at: now, delivery_attempt: 1, event_id: "evt_1",
                                  event_type: "payment.created", correlation_id: "corr-1",
                                  body_bytes: body.bytesize, raw_event_id: raw_events.first[:id],
                                  connection_id: connection.id, operator_id: operator.id)
    expect(rows.first[:body_sha256]).to eq(Digest::SHA256.digest(body))
    expect(receipts.columns).not_to include(:body, :payload)
  end

  it "writes a receipt for a rejection found before the envelope was read" do
    result = described_class.reject!("bad_signature", body: "xyz", delivery: delivery)
    expect(result).to have_attributes(outcome: "rejected", reason: "bad_signature")
    expect(receipts.first).to include(reason: "bad_signature", pms_client_id: nil, body_bytes: 3,
                                      event_id: "evt_1", outcome: "rejected")
  end

  it "refuses an unknown reason" do
    expect { described_class.reject!("because", body: "", delivery: delivery) }.to raise_error(ArgumentError)
  end

  describe "the raw_events trigger (Constitution I)" do
    before { record }

    it "raises on UPDATE" do
      expect { Rentsync.db.transaction(savepoint: true) { raw_events.update(event_type: "lease.updated") } }
        .to raise_error(Sequel::DatabaseError, /immutable/)
    end

    it "raises on DELETE" do
      expect { Rentsync.db.transaction(savepoint: true) { raw_events.delete } }
        .to raise_error(Sequel::DatabaseError, /immutable/)
      expect(raw_events.count).to eq(1)
    end
  end
end
