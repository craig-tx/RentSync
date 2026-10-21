# frozen_string_literal: true

require "spec_helper"

RSpec.describe "POST /admin/reset", type: :request do
  def app = MockPms::App.build

  let(:admin) { { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}", "CONTENT_TYPE" => "application/json" } }

  def reset!(headers = {})
    post "/admin/reset", JSON.generate(seed: 42, anchor_date: "2026-10-20"), admin.merge(headers)
    JSON.parse(last_response.body)
  end

  it "reseeds and returns the same digest as bin/reseed would" do
    body = reset!
    expect(last_response.status).to eq(200)
    expected = MockPms::Seed::Reset.run!(seed: 42, anchor_date: Date.new(2026, 10, 20))[:data_digest]
    expect(body).to eq("seed" => 42, "anchor_date" => "2026-10-20", "data_digest" => expected)
  end

  it "clears clients, grants, deliveries and chaos counters but keeps metrics and audit tables" do
    client = Factory.client.first
    MockPms::Metrics.increment("mock_pms_http_requests_total", { route: "/x", method: "GET", status: "200" })
    MockPms::Metrics.flush!
    MockPms::Chaos::Decider.draw!(:delivery)
    MockPms.db[:admin_idempotency_keys].insert(key: "old", request_digest: "d", response_status: 200,
                                               response_body: Sequel.pg_jsonb_wrap({}))
    reset!
    expect(MockPms::Client[client.seq]).to be_nil
    expect(MockPms::Grant.count).to eq(0)
    expect(MockPms::Delivery.count).to eq(0)
    expect(MockPms.db[:chaos_counters].select_map(:value)).to eq([0, 0])
    expect(MockPms.db[:admin_idempotency_keys].where(key: "old").count).to eq(1)
    expect(MockPms::Redis.client.hgetall(MockPms::Redis.key("metrics", "mock_pms_http_requests_total"))).not_to be_empty
  end

  it "requires the admin token" do
    post "/admin/reset", "{}", { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(401)
  end

  it "does not reseed again for a repeated Idempotency-Key" do
    runs_before = MockPms.db[:seed_runs].count
    first = reset!("HTTP_IDEMPOTENCY_KEY" => "reset-1")
    second = reset!("HTTP_IDEMPOTENCY_KEY" => "reset-1")
    expect(second).to eq(first)
    expect(MockPms.db[:seed_runs].count).to eq(runs_before + 1)
  end
end
