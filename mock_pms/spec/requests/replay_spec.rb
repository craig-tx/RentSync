# frozen_string_literal: true

require "spec_helper"

RSpec.describe "admin replays", type: :request do
  def app = MockPms::App.build

  let(:admin) { { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}", "CONTENT_TYPE" => "application/json" } }
  let(:op) { Factory.operator }
  let(:client) { Factory.client(subscriber_url: "http://receiver.test/webhooks").first }

  def event_at(time, type: "payment.created")
    MockPms::Events::Recorder.record!(type: type, operator_seq: op.seq, payload: { "id" => "pay_#{time.to_i}" },
                                      occurred_at: time, source: "seed")
  end

  def json = JSON.parse(last_response.body)

  it "replays one event with replay: true and the original event", :aggregate_failures do
    seeded = event_at(Time.utc(2026, 3, 1)) # recorded before any subscriber: no deliveries
    expect(MockPms::Delivery.where(event_seq: seeded.seq).count).to eq(0)
    Factory.tokens(client, op)
    post "/admin/events/#{seeded.id}/replay", JSON.generate(client_id: client.id), admin
    expect(last_response.status).to eq(202)
    expect(json).to include("event_id" => seeded.id, "client_id" => client.id, "replay" => true, "status" => "pending")
  end

  it "refuses with 409 without an active grant or a subscriber_url" do
    event = event_at(Time.utc(2026, 3, 1))
    post "/admin/events/#{event.id}/replay", JSON.generate(client_id: client.id), admin
    expect(last_response.status).to eq(409)
    quiet = Factory.client.first
    Factory.tokens(quiet, op)
    post "/admin/events/#{event.id}/replay", JSON.generate(client_id: quiet.id), admin
    expect(last_response.status).to eq(409)
  end

  it "replays a time range in occurred_at order, filtered by type" do
    Factory.tokens(client, op)
    MockPms::Delivery.dataset.delete
    times = [Time.utc(2026, 3, 5), Time.utc(2026, 3, 1), Time.utc(2026, 3, 3), Time.utc(2026, 4, 1)]
    times.each { |t| event_at(t) }
    event_at(Time.utc(2026, 3, 2), type: "lease.updated")
    MockPms::Delivery.dataset.delete
    post "/admin/replays", JSON.generate(client_id: client.id, from: "2026-03-01T00:00:00Z",
                                         to: "2026-04-01T00:00:00Z", types: ["payment.created"]), admin
    expect(last_response.status).to eq(202)
    expect(json).to eq("queued" => 3)
    order = MockPms::Delivery.where(replay: true).order(:scheduled_at, :seq).all.map { |d| d.event.occurred_at }
    expect(order).to eq([Time.utc(2026, 3, 1), Time.utc(2026, 3, 3), Time.utc(2026, 3, 5)])
  end

  it "sends PMS-Replay with the original event id, type and payload" do
    Factory.tokens(client, op)
    event = event_at(Time.utc(2026, 3, 1))
    MockPms::Delivery.dataset.delete
    post "/admin/events/#{event.id}/replay", JSON.generate(client_id: client.id), admin
    transport = FakeTransport.new
    MockPms::Delivery::Worker.new(transport: transport, worker_id: "w").run_once
    sent = transport.requests.first
    expect(sent[:headers]).to include("PMS-Replay" => "true", "PMS-Event-Id" => event.id,
                                      "PMS-Event-Type" => "payment.created")
    expect(JSON.parse(sent[:body])).to include("id" => event.id, "occurred_at" => "2026-03-01T00:00:00Z",
                                               "data" => { "object" => { "id" => "pay_#{Time.utc(2026, 3, 1).to_i}" } })
  end
end
