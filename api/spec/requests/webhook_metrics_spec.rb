# frozen_string_literal: true

require "spec_helper"

# T045, research R16 and FR-024: receipts, raw events and the acknowledgement time are counted
# with labels from fixed lists, so no label can carry an operator email, a token or tenant data.
RSpec.describe "webhook metrics", type: :request do
  def app = Rentsync::App.build

  let(:secret) { "SS-METRICS-0123456789" }
  let(:marker) { "Tess-Tenant-#{SecureRandom.hex(4)}" }
  let!(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: secret
    )
  end

  before do
    operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
                                   pms_operator_name: "Lone Star Rentals", status: "active")
    Rentsync::Metrics.reset!
  end

  def deliver(id:, operator_id: "op_1", type: "payment.created", sign_with: secret, header_type: type)
    body = JSON.generate("id" => id, "type" => type, "occurred_at" => "2026-10-31T14:05:12Z",
                         "operator_id" => operator_id, "api_version" => "2026-10-01",
                         "data" => { "object" => { "id" => "pay_#{id}", "tenant" => marker } })
    t = Time.now.to_i
    signature = "t=#{t},v1=#{OpenSSL::HMAC.hexdigest('SHA256', sign_with, "#{t}.#{body}")}"
    post "/webhooks/pms", body, "CONTENT_TYPE" => "application/json", "HTTP_PMS_EVENT_ID" => id,
                                "HTTP_PMS_EVENT_TYPE" => header_type, "HTTP_PMS_DELIVERY_ID" => "dlv_#{marker}",
                                "HTTP_PMS_SIGNATURE" => signature, "HTTP_X_CORRELATION_ID" => "corr-#{marker}"
  end

  it "counts receipts by outcome and reason, and raw events by path and body type" do
    deliver(id: "evt_1")
    deliver(id: "evt_1")
    deliver(id: "evt_2", type: "lease.updated", header_type: "x-#{marker}")
    deliver(id: "evt_3", operator_id: "op_#{marker}")
    deliver(id: "evt_4", sign_with: "wrong")
    deltas = Rentsync::Metrics.buffer.swap![:counters]
    expect(deltas["rentsync_webhook_receipts_total"]).to eq(
      "outcome=recorded|reason=none" => 2, "outcome=duplicate|reason=none" => 1,
      "outcome=rejected|reason=unknown_operator" => 1, "outcome=rejected|reason=bad_signature" => 1
    )
    expect(deltas["rentsync_raw_events_total"]).to eq(
      "arrival_path=webhook|type=payment.created" => 1, "arrival_path=webhook|type=lease.updated" => 1
    )
  end

  it "times every acknowledgement in a histogram with a 2 s boundary (SC-006)" do
    deliver(id: "evt_1")
    deliver(id: "evt_2", sign_with: "wrong")
    histograms = Rentsync::Metrics.buffer.swap![:histograms]
    expect(histograms.fetch("rentsync_webhook_ack_seconds").values.sum { |h| h[:count] }).to eq(2)
    expect(Rentsync::Metrics::BUCKETS).to include(0.05, 2, 5)
  end

  it "never puts an email, a token, a header value or tenant data in a label" do
    deliver(id: "evt_1", header_type: "x-#{marker}")
    deliver(id: "evt_9", operator_id: "op_#{marker}")
    labels = Rentsync::Metrics.buffer.swap!.values.flat_map(&:values).flat_map(&:keys).join("\n")
    expect(labels).not_to include(marker, "ann@example.test", secret, "op_1", "evt_")
  end

  it "registers the families so /metrics renders them" do
    expect(Rentsync::Metrics::FAMILIES.keys).to include(
      "rentsync_webhook_receipts_total", "rentsync_raw_events_total", "rentsync_webhook_ack_seconds"
    )
  end
end
