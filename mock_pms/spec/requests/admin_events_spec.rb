# frozen_string_literal: true

require "spec_helper"

RSpec.describe "admin events, deliveries and scenarios", type: :request do
  def app = MockPms::App.build

  let(:op) { Factory.operator }
  let!(:lease) { Factory.lease(op) }
  let!(:client) do
    Factory.client(subscriber_url: "http://receiver.test/webhooks").first.tap { |c| Factory.tokens(c, op) }
  end

  def admin(extra = {})
    { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}", "CONTENT_TYPE" => "application/json" }.merge(extra)
  end

  def json = JSON.parse(last_response.body)

  it "runs a scenario and returns a ScenarioResult" do
    post "/admin/scenarios/tenant_move_out", "{}", admin
    expect(last_response.status).to eq(200)
    expect(json).to include("scenario" => "tenant_move_out", "events_created" => 2)
    expect(json["run_id"]).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "is 404 for an unknown scenario" do
    post "/admin/scenarios/nope", "{}", admin
    expect(last_response.status).to eq(404)
  end

  it "replays the stored result for a repeated Idempotency-Key without new events" do
    post "/admin/scenarios/tenant_move_out", "{}", admin("HTTP_IDEMPOTENCY_KEY" => "move-1")
    first = json
    post "/admin/scenarios/tenant_move_out", "{}", admin("HTTP_IDEMPOTENCY_KEY" => "move-1")
    expect(json["run_id"]).to eq(first["run_id"])
    expect(MockPms::Event.count).to eq(2)
  end

  it "lists events with filters and pagination, as webhook envelopes" do
    post "/admin/scenarios/tenant_move_out", "{}", admin
    get "/admin/events", { type: "tenant.moved_out", operator_id: op.id, limit: 1 }, admin
    expect(json["data"].size).to eq(1)
    expect(json["data"].first).to include("type" => "tenant.moved_out", "operator_id" => op.id,
                                          "api_version" => "2026-10-01")
    expect(json["data"].first["data"]["object"].keys).to include("tenant", "lease", "move_out_date")
    expect(json).to have_key("next_cursor")
  end

  it "lists deliveries with their attempts" do
    post "/admin/scenarios/tenant_move_out", "{}", admin
    event_id = MockPms::Event.first(type: "lease.updated").id
    get "/admin/deliveries", { event_id: event_id }, admin
    expect(json["data"].size).to eq(1)
    delivery = json["data"].first
    expect(delivery).to include("event_id" => event_id, "client_id" => client.id, "status" => "pending",
                                "attempt_count" => 0, "replay" => false, "chaos" => {}, "attempts" => [])
    expect(delivery["id"]).to start_with("dlv_")
  end
end
