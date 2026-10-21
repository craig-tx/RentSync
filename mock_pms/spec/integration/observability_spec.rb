# frozen_string_literal: true

require "spec_helper"

RSpec.describe "observability end to end" do
  def app = MockPms::App.build

  include Rack::Test::Methods

  let(:io) { StringIO.new }

  around do |example|
    original = MockPms::Logging.io
    MockPms::Logging.io = io
    example.run
  ensure
    MockPms::Logging.io = original
  end

  it "writes only JSON lines with service.name and code.function.name, and never secrets (FR-031)" do
    op = Factory.operator(login: "obs")
    Factory.lease(op)
    client, secret = Factory.client(subscriber_url: "http://127.0.0.1:1/webhooks")
    _, tokens = Factory.tokens(client, op)
    get "/v1/payments", {}, { "HTTP_AUTHORIZATION" => "Bearer #{tokens[:access_token]}" }
    post "/oauth/token", grant_type: "refresh_token", refresh_token: tokens[:refresh_token], client_id: client.id,
                         client_secret: secret
    get "/admin/chaos", {}, { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}" }
    MockPms::Scenarios::TenantMoveOut.run!
    MockPms::Delivery::Worker.new(transport: FakeTransport.new, worker_id: "obs").run_once

    lines = io.string.lines
    expect(lines.size).to be > 5
    lines.each do |line|
      record = JSON.parse(line)
      expect(record["service.name"]).to start_with("mock_pms-")
      expect(record["code.function.name"]).to be_a(String).and(satisfy { |f| !f.empty? })
    end
    raw = io.string
    secrets = [secret, client.signing_secret, tokens[:access_token], tokens[:refresh_token], "obs-pass",
               ENV.fetch("ADMIN_TOKEN")]
    secrets.each { |s| expect(raw).not_to include(s) }
    tenant = MockPms::Tenant.first(operator_seq: op.seq)
    [tenant.email, tenant.phone].each { |pii| expect(raw).not_to include(pii) }
  end

  it "exposes request, delivery, rate-limit and dropped-metric families plus target_info" do
    MockPms::Metrics.increment("mock_pms_rate_limited_total", { client_id: "client_X" })
    MockPms::Metrics.increment(MockPms::Metrics::DROPPED, {})
    get "/healthz/live"
    MockPms::Metrics.flush!
    get "/metrics"
    body = last_response.body
    %w[target_info mock_pms_http_requests_total mock_pms_http_request_duration_seconds_bucket
       mock_pms_rate_limited_total mock_pms_metrics_dropped_total mock_pms_delivery_queue_depth].each do |family|
      expect(body).to include(family)
    end
  end

  it "delivers a default month-end burst within 120 s (SC-008)", :committed, :slow do
    receiver = RecordingReceiver.new
    port, stop = ReceiverServer.start(receiver)
    op = Factory.operator
    10.times { Factory.lease(op, start_date: Date.new(2026, 1, 1)) }
    client = Factory.client(subscriber_url: "http://127.0.0.1:#{port}/webhooks").first
    Factory.tokens(client, op)
    started = Time.now
    result = MockPms::Scenarios::MonthEndBurst.run!
    expect(result[:events_created]).to be >= 7 # at least 70% of 10 active leases
    worker = MockPms::Delivery::Worker.new(worker_id: "burst")
    worker.run_once until MockPms::Delivery.exclude(status: "succeeded").empty? || Time.now - started > 120
    expect(receiver.requests.size).to eq(result[:events_created])
    expect(Time.now - started).to be < 120
  ensure
    stop&.call
  end
end
