# frozen_string_literal: true

require "spec_helper"
require "net/http"

# T039, Constitution III: a real signed HTTP request through the full Rack stack, on a local
# Puma, to the persisted raw event and receipt; and contracts/webhook-receiver.md's table of
# reasons and HTTP statuses. Committed, so "200 only after commit" is a real commit.
RSpec.describe "POST /webhooks/pms end to end", :committed do
  let(:secret) { "SS-E2E-0123456789" }
  let!(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: secret
    )
  end
  let!(:connection) do
    operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
                                   pms_operator_name: "Lone Star Rentals", status: "active", connected_at: Time.now.utc)
  end

  before(:context) { @port, @stop = ReceiverServer.start(Rentsync::App.build) }
  after(:context) { @stop.call }

  def body_for(id: "evt_1", operator_id: "op_1", object: { "id" => "pay_1", "tenant" => "Tess Tenant" })
    # Spacing and key order a re-serializer would change, to prove the stored bytes are the sent ones.
    %({"type":"payment.created", "id":"#{id}","occurred_at":"2026-10-31T14:05:12Z","operator_id":"#{operator_id}",) +
      %("api_version":"2026-10-01","data":{"object":#{JSON.generate(object)}}})
  end

  def signature(body, secret: self.secret, t: Time.now.to_i)
    "t=#{t},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{t}.#{body}")}"
  end

  def headers_for(body, event_id: JSON.parse(body)["id"], **overrides)
    { "Content-Type" => "application/json; charset=utf-8", "PMS-Event-Id" => event_id,
      "PMS-Event-Type" => "payment.created", "PMS-Delivery-Id" => "dlv_1", "PMS-Delivery-Attempt" => "1",
      "PMS-Signature" => signature(body), "X-Correlation-Id" => "corr-pms-1" }.merge(overrides).compact
  end

  def deliver(body, path: "/webhooks/pms", method: Net::HTTP::Post, **headers)
    Net::HTTP.start("127.0.0.1", @port, read_timeout: 10) do |http|
      request = method.new(path, headers_for(body, **headers))
      request.body = body if request.request_body_permitted?
      http.request(request)
    end
  end

  def raw_events = Rentsync.db[:raw_events]
  def receipts = Rentsync.db[:webhook_receipts]
  def error_code(response) = JSON.parse(response.body).dig("error", "code")

  it "records the raw event and its receipt from a signed request, byte for byte" do
    body = body_for
    response = deliver(body, "X-Request-Id" => "req-from-a-proxy")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("outcome" => "recorded", "event_id" => "evt_1")
    expect(response["X-Correlation-Id"]).to eq("corr-pms-1")

    row = raw_events.first
    expect(row[:payload_raw]).to eq(body.b)
    expect(JSON.parse(row[:payload].to_json)).to eq(JSON.parse(body))
    expect(row).to include(connection_id: connection.id, arrival_path: "webhook", correlation_id: "corr-pms-1")
    expect(receipts.first).to include(outcome: "recorded", raw_event_id: row[:id], delivery_id: "dlv_1",
                                      correlation_id: "corr-pms-1")
  end

  it "answers 200 for a repeat delivery without a second raw event" do
    body = body_for
    deliver(body)
    response = deliver(body, "PMS-Delivery-Id" => "dlv_2")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("outcome" => "duplicate", "event_id" => "evt_1")
    expect(raw_events.count).to eq(1)
    expect(receipts.select_map(:outcome).sort).to eq(%w[duplicate recorded])
  end

  it "generates a correlation ID when the request has none, and stores and returns it" do
    response = deliver(body_for, "X-Correlation-Id" => nil)
    generated = response["X-Correlation-Id"]
    expect(generated).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    expect(raw_events.first[:correlation_id]).to eq(generated)
  end

  it "answers 500 when recording fails after the insert, leaving no raw event (FR-011)" do
    calls = 0
    allow(Rentsync::Webhooks::Recorder).to receive(:write_receipt).and_wrap_original do |original, *args, **kw|
      calls += 1
      result = original.call(*args, **kw)
      raise "injected failure after the insert" if calls == 1

      result
    end
    response = deliver(body_for)
    expect(response.code).to eq("500")
    expect(JSON.parse(response.body)).to eq("error" => { "code" => "internal_error" })
    expect(raw_events.count).to eq(0)
    expect(receipts.select_map(%i[outcome reason])).to eq([%w[rejected internal_error]])
  end

  describe "the contract's reasons and statuses" do
    let(:marker) { "MARKER-#{SecureRandom.hex(4)}" }

    def expect_rejected(response, status, reason)
      expect(response.code).to eq(status.to_s)
      expect(error_code(response)).to eq(reason)
      expect(response.body).not_to include(marker, secret, "Tess Tenant")
      expect(receipts.order(:id).last).to include(outcome: "rejected", reason: reason)
      expect(raw_events.count).to eq(0)
    end

    it "413 body_too_large" do
      body = body_for(object: { "id" => "pay_1", "pad" => marker + ("x" * (256 * 1024)) })
      expect_rejected(deliver(body), 413, "body_too_large")
    end

    it "401 missing_signature" do
      expect_rejected(deliver(body_for, "PMS-Signature" => nil), 401, "missing_signature")
      expect_rejected(deliver(body_for, "PMS-Signature" => "t=1,v1=#{marker}"), 401, "missing_signature")
    end

    it "401 bad_signature" do
      body = body_for
      expect_rejected(deliver(body, "PMS-Signature" => signature(body, secret: "wrong-#{marker}")), 401,
                      "bad_signature")
    end

    it "401 bad_signature for a superseded registration's secret: only the active client's counts" do
      Rentsync::PmsClient.create_with_secrets(
        { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_OLD", registered_at: Time.now.utc,
          superseded_at: Time.now.utc },
        client_secret: "CS-OLD", signing_secret: "SS-OLD-#{marker}"
      )
      body = body_for
      expect_rejected(deliver(body, "PMS-Signature" => signature(body, secret: "SS-OLD-#{marker}")), 401,
                      "bad_signature")
    end

    it "401 stale_timestamp" do
      body = body_for
      expect_rejected(deliver(body, "PMS-Signature" => signature(body, t: Time.now.to_i - 301)), 401,
                      "stale_timestamp")
    end

    it "422 malformed_body" do
      body = body_for(object: { "id" => "pay_1", "note" => marker })
      expect_rejected(deliver(body.byteslice(0, body.bytesize / 2), event_id: "evt_1"), 422, "malformed_body")
      expect_rejected(deliver(body, event_id: "evt_#{marker}"), 422, "malformed_body")
    end

    it "422 unknown_operator" do
      expect_rejected(deliver(body_for(operator_id: "op_#{marker}")), 422, "unknown_operator")
    end

    it "422 no_active_connection" do
      connection.this.update(status: "disconnected")
      expect_rejected(deliver(body_for), 422, "no_active_connection")
    end

    it "422 conflicting_duplicate" do
      deliver(body_for)
      response = deliver(body_for(object: { "id" => "pay_1", "note" => marker }))
      expect(response.code).to eq("422")
      expect(error_code(response)).to eq("conflicting_duplicate")
      expect(response.body).not_to include(marker)
      expect(raw_events.count).to eq(1)
    end
  end

  describe "attributing rejections to an operator (US4)" do
    it "attributes a validly signed but malformed delivery from its authenticated body, never its headers" do
      dropped = JSON.generate(JSON.parse(body_for).except("data"))
      deliver(dropped, "PMS-Event-Id" => "evt_FROM_HEADER", "PMS-Event-Type" => "x-header")
      long = body_for(object: { "id" => "pay_1", "pad" => "x" * 400 })
      deliver(long.byteslice(0, long.bytesize / 2), event_id: "evt_1")
      rows = receipts.order(:id).all
      expect(rows.map { |r| r[:reason] }).to eq(%w[malformed_body malformed_body])
      expect(rows.map { |r| [r[:operator_id], r[:connection_id]] }.uniq)
        .to eq([[connection.operator_id, connection.id]])
      expect(rows.first).to include(event_id: "evt_1", event_type: "payment.created")
    end

    it "attributes a stale but genuine delivery, and never one whose signature failed" do
      body = body_for
      deliver(body, "PMS-Signature" => signature(body, t: Time.now.to_i - 600))
      deliver(body, "PMS-Signature" => signature(body, secret: "wrong"))
      rows = receipts.order(:id).all
      expect(rows.map { |r| [r[:reason], r[:operator_id]] })
        .to eq([["stale_timestamp", connection.operator_id], ["bad_signature", nil]])
    end
  end

  describe "other requests to the path" do
    it "answers 405 to anything but POST, and 404 below the path, without receipts" do
      expect(deliver(body_for, method: Net::HTTP::Get).code).to eq("405")
      expect(deliver(body_for, path: "/webhooks/pms/extra").code).to eq("404")
      expect(receipts.count).to eq(0)
    end
  end
end
