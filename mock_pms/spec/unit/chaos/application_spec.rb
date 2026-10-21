# frozen_string_literal: true

require "spec_helper"

RSpec.describe "chaos applied by the recorder and the worker" do
  let(:op) { Factory.operator }
  let(:t0) { Time.utc(2026, 10, 20, 12) }
  let!(:client) do
    Factory.client(subscriber_url: "http://receiver.test/webhooks").first.tap { |c| Factory.tokens(c, op) }
  end

  before { freeze_time(t0) }

  def record!
    MockPms::Events::Recorder.record!(type: "payment.created", operator_seq: op.seq, payload: { "id" => "pay_1" },
                                      occurred_at: t0, source: "admin")
  end

  def with_decision(decision, copy: {})
    allow(MockPms::Chaos::Decider).to receive(:decide_delivery!).and_return(decision)
    allow(MockPms::Chaos::Decider).to receive(:decide_copy!).and_return(copy)
  end

  it "adds a duplicate copy pointing at the first delivery, with its own malform decision" do
    with_decision({ "duplicate" => true, "malform" => "truncate" }, copy: { "malform" => "bad_type" })
    event = record!
    first, copy = MockPms::Delivery.where(event_seq: event.seq).order(:seq).all
    expect(first.chaos.to_h).to eq("malform" => "truncate")
    expect(copy.chaos.to_h).to eq("duplicate_of" => first.id, "malform" => "bad_type")
    expect(copy.client_seq).to eq(first.client_seq)
  end

  it "holds out-of-order and delayed deliveries by the decided seconds" do
    with_decision({ "reorder_hold_s" => 4, "delayed_s" => 6 })
    event = record!
    delivery = MockPms::Delivery.first(event_seq: event.seq)
    expect(delivery.scheduled_at).to eq(t0 + 10)
    expect(delivery.chaos.to_h).to eq("reorder_hold_s" => 4, "delayed_s" => 6)
  end

  it "sends the malformed body and records chaos_applied, without touching the stored event" do
    with_decision({ "malform" => "drop_field" })
    event = record!
    transport = FakeTransport.new
    MockPms::Delivery::Worker.new(transport: transport, worker_id: "w").run_once
    sent = JSON.parse(transport.requests.first[:body])
    expect(sent.keys).not_to include("data")
    attempt = MockPms::DeliveryAttempt.first
    expect(attempt.chaos_applied.to_h).to eq("malform" => "drop_field")
    expect(event.refresh.payload.to_h).to eq("id" => "pay_1")
  end
end
