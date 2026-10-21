# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Delivery::Worker do
  let(:op) { Factory.operator }
  let(:t0) { Time.utc(2026, 10, 20, 12) }
  let(:schedule) { MockPms::Delivery::RetrySchedule.new(base: 2, max_attempts: 8, jitter: -> { 0.0 }) }

  before { freeze_time(t0) }

  def setup_event
    client = Factory.client(subscriber_url: "http://receiver.test/webhooks").first
    Factory.tokens(client, op)
    Thread.current[:correlation_id] = "corr-1"
    event = MockPms::Events::Recorder.record!(type: "payment.created", operator_seq: op.seq,
                                              payload: { "id" => "pay_A" }, occurred_at: t0 - 60, source: "admin")
    Thread.current[:correlation_id] = nil
    [client, event, MockPms::Delivery.first(event_seq: event.seq)]
  end

  def worker(transport) = described_class.new(transport: transport, schedule: schedule, worker_id: "w-test")

  it "delivers the signed envelope with all headers and records a success attempt" do
    client, event, delivery = setup_event
    transport = FakeTransport.new
    worker(transport).run_once
    expect(transport.requests.size).to eq(1)
    req = transport.requests.first
    expect(req[:url]).to eq("http://receiver.test/webhooks")
    expect(req[:headers]).to include("Content-Type" => "application/json; charset=utf-8",
                                     "PMS-Event-Id" => event.id, "PMS-Event-Type" => "payment.created",
                                     "PMS-Delivery-Id" => delivery.id, "PMS-Delivery-Attempt" => "1",
                                     "X-Correlation-Id" => "corr-1")
    expect(req[:headers]).not_to include("PMS-Replay")
    expect(MockPms::Delivery::Signer.verify(header: req[:headers]["PMS-Signature"], secret: client.signing_secret,
                                            body: req[:body])).to be(true)
    envelope = JSON.parse(req[:body])
    expect(envelope).to eq("id" => event.id, "type" => "payment.created",
                           "occurred_at" => (t0 - 60).iso8601, "operator_id" => op.id,
                           "api_version" => "2026-10-01", "data" => { "object" => { "id" => "pay_A" } })
    expect(delivery.refresh.status).to eq("succeeded")
    attempt = MockPms::DeliveryAttempt.first(delivery_seq: delivery.seq)
    expect(attempt.values).to include(attempt_number: 1, outcome: "success", http_status: 200,
                                      correlation_id: "corr-1")
  end

  it "records each failure kind and reschedules with the retry schedule, keeping the event id" do
    _, event, delivery = setup_event
    transport = FakeTransport.new([{ outcome: "http_error", http_status: 500 }, { outcome: "timeout" },
                                   { outcome: "connection_error" }])
    w = worker(transport)
    w.run_once
    expect(delivery.refresh.values).to include(status: "pending", attempt_count: 1, scheduled_at: t0 + 2)
    advance(2)
    w.run_once
    expect(delivery.refresh.scheduled_at).to eq(t0 + 2 + 4)
    advance(4)
    w.run_once
    advance(8)
    w.run_once
    outcomes = MockPms::DeliveryAttempt.where(delivery_seq: delivery.seq).order(:attempt_number).select_map(:outcome)
    expect(outcomes).to eq(%w[http_error timeout connection_error success])
    expect(transport.requests.map { |r| r[:headers]["PMS-Event-Id"] }.uniq).to eq([event.id])
    expect(transport.requests.map { |r| r[:headers]["PMS-Delivery-Attempt"] }).to eq(%w[1 2 3 4])
    expect(delivery.refresh.status).to eq("succeeded")
  end

  it "signs every attempt with a fresh timestamp" do
    setup_event
    transport = FakeTransport.new([{ outcome: "http_error", http_status: 500 }])
    w = worker(transport)
    w.run_once
    advance(2)
    w.run_once
    stamps = transport.requests.map { |r| r[:headers]["PMS-Signature"][/t=(\d+)/, 1].to_i }
    expect(stamps).to eq([t0.to_i, t0.to_i + 2])
  end

  it "marks the delivery exhausted after the 8th failure" do
    _, _, delivery = setup_event
    transport = FakeTransport.new(Array.new(8) { { outcome: "http_error", http_status: 503 } })
    w = worker(transport)
    8.times do
      w.run_once
      advance(300)
    end
    expect(delivery.refresh.values).to include(status: "exhausted", attempt_count: 8)
  end

  it "requeues deliveries stuck in_flight for more than 60 s" do
    _, _, delivery = setup_event
    delivery.update(status: "in_flight", updated_at: t0 - 61)
    worker(FakeTransport.new).reap!
    expect(delivery.refresh.status).to eq("pending")
  end

  it "writes a heartbeat" do
    worker(FakeTransport.new).run_once
    expect(MockPms.db[:worker_heartbeats].first(worker_id: "w-test")[:beat_at]).to eq(t0)
  end

  it "never lets two concurrent workers claim the same delivery", :committed do
    MockPms::Clock.override = nil
    op = Factory.operator
    client = Factory.client(subscriber_url: "http://receiver.test/webhooks").first
    Factory.tokens(client, op)
    30.times do |i|
      MockPms::Events::Recorder.record!(type: "payment.created", operator_seq: op.seq, payload: { "i" => i },
                                        occurred_at: Time.now.utc, source: "admin")
    end
    transport = FakeTransport.new
    threads = Array.new(2) { |i| Thread.new { described_class.new(transport: transport, worker_id: "w#{i}").run_once } }
    threads.each(&:join)
    ids = transport.requests.map { |r| r[:headers]["PMS-Delivery-Id"] }
    expect(ids.size).to eq(ids.uniq.size)
  end
end
