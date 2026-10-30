# frozen_string_literal: true

require "spec_helper"

# T044, contracts/openapi.yaml "Admin": raw event metadata for comparison with the PMS
# (quickstart §3) and receipt counts, behind the admin token. Never payloads.
RSpec.describe "admin", type: :request do
  def app = Rentsync::App.build

  let(:token) { "test-mock-admin-token" }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end
  let(:now) { Time.utc(2026, 10, 31, 14, 6) }

  def connect(pms_operator_id)
    operator = Rentsync::Operator.create(email: "#{pms_operator_id}@example.test", name: "N", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id,
                                   pms_operator_id: pms_operator_id, pms_operator_name: "PMS", status: "active")
  end

  def raw_event(connection, event_id, type: "lease.updated", business_key: nil)
    body = JSON.generate("id" => event_id, "tenant" => "Tess Tenant")
    Rentsync.db[:raw_events].insert(
      pms_client_id: pms_client.id, connection_id: connection.id, event_id: event_id, business_key: business_key,
      event_type: type, occurred_at: now, received_at: now, arrival_path: "webhook",
      payload_raw: Sequel.blob(body), payload: Sequel.pg_jsonb_wrap(JSON.parse(body)),
      payload_sha256: Sequel.blob(Digest::SHA256.digest(body)), correlation_id: "corr"
    )
  end

  def receipt(outcome, reason = nil)
    Rentsync.db[:webhook_receipts].insert(received_at: now, outcome: outcome, reason: reason,
                                          duplicate_of_path: outcome == "duplicate" ? "webhook" : nil,
                                          body_bytes: 1, body_sha256: Sequel.blob("x"), correlation_id: "c")
  end

  def admin_get(path, params = {}, auth: "Bearer #{token}")
    get(path, params, auth ? { "HTTP_AUTHORIZATION" => auth } : {})
    JSON.parse(last_response.body)
  end

  describe "the admin token" do
    it "refuses a missing, empty, wrong or non-Bearer token with 401" do
      [nil, "", "Bearer", "Bearer ", "Bearer wrong", "Basic #{token}", token].each do |auth|
        body = admin_get("/admin/receipts", auth: auth)
        expect(last_response.status).to eq(401), auth.inspect
        expect(body.dig("error", "code")).to eq("unauthorized")
      end
    end

    it "compares in constant time" do
      expect(OpenSSL).to receive(:fixed_length_secure_compare).and_call_original
      admin_get("/admin/receipts")
      expect(last_response.status).to eq(200)
    end
  end

  describe "GET /admin/raw_events" do
    let!(:first) { connect("op_1") }
    let!(:second) { connect("op_2") }

    before do
      raw_event(first, "evt_1")
      raw_event(first, "evt_2", type: "payment.created", business_key: "payment.created:pay_1")
      raw_event(second, "evt_3")
    end

    it "lists metadata only, oldest first, never payloads" do
      body = admin_get("/admin/raw_events")
      expect(last_response.status).to eq(200)
      expect(body["data"].first).to eq("event_id" => "evt_1", "business_key" => nil, "event_type" => "lease.updated",
                                       "occurred_at" => now.iso8601, "arrival_path" => "webhook",
                                       "pms_operator_id" => "op_1")
      expect(body["data"].map { |e| e["event_id"] }).to eq(%w[evt_1 evt_2 evt_3])
      expect(last_response.body).not_to include("Tess Tenant", "payload")
      expect(body["next_cursor"]).to be_nil
    end

    it "filters by PMS operator" do
      body = admin_get("/admin/raw_events", { pms_operator_id: "op_2" })
      expect(body["data"].map { |e| e["event_id"] }).to eq(%w[evt_3])
    end

    it "pages with an opaque cursor" do
      first_page = admin_get("/admin/raw_events", { limit: 2 })
      expect(first_page["data"].size).to eq(2)
      second_page = admin_get("/admin/raw_events", { limit: 2, cursor: first_page["next_cursor"] })
      expect(second_page["data"].map { |e| e["event_id"] }).to eq(%w[evt_3])
      expect(second_page["next_cursor"]).to be_nil
    end

    it "refuses a bad cursor or limit with 422" do
      admin_get("/admin/raw_events", { cursor: "nope" })
      expect(last_response.status).to eq(422)
      admin_get("/admin/raw_events", { limit: 0 })
      expect(last_response.status).to eq(422)
    end
  end

  describe "GET /admin/receipts" do
    it "counts receipts by outcome and reason across all operators, including unknown_operator" do
      2.times { receipt("recorded") }
      receipt("duplicate")
      3.times { receipt("rejected", "unknown_operator") }
      receipt("rejected", "bad_signature")
      body = admin_get("/admin/receipts")
      expect(body["total"]).to eq(7)
      expect(body["counts"]).to contain_exactly(
        { "outcome" => "recorded", "reason" => nil, "count" => 2 },
        { "outcome" => "duplicate", "reason" => nil, "count" => 1 },
        { "outcome" => "rejected", "reason" => "unknown_operator", "count" => 3 },
        { "outcome" => "rejected", "reason" => "bad_signature", "count" => 1 }
      )
    end
  end
end
