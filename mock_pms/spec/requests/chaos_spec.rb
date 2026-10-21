# frozen_string_literal: true

require "spec_helper"

RSpec.describe "chaos settings and injected API errors", type: :request do
  def app = MockPms::App.build

  let(:admin) { { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}", "CONTENT_TYPE" => "application/json" } }
  let(:op) { Factory.operator }
  let(:client) { Factory.client(rate_limit_per_minute: 1000).first }
  let(:token) { Factory.tokens(client, op).last[:access_token] }

  def put_chaos(body) = put("/admin/chaos", JSON.generate(body), admin)

  it "returns the defaults: every rate 0, delay 5-60 s, seed 1" do
    get "/admin/chaos", {}, admin
    expect(JSON.parse(last_response.body)).to include(
      "duplicate_rate" => 0.0, "out_of_order_rate" => 0.0, "delay_rate" => 0.0, "server_error_rate" => 0.0,
      "malformed_rate" => 0.0, "delay_min_s" => 5, "delay_max_s" => 60, "seed" => 1
    )
  end

  it "rejects out-of-range values with 422" do
    [{ duplicate_rate: 1.5 }, { malformed_rate: -0.1 }, { delay_min_s: 10, delay_max_s: 5 },
     { delay_max_s: 3601 }].each do |bad|
      put_chaos(bad)
      expect(last_response.status).to eq(422), "expected 422 for #{bad}"
    end
  end

  it "injects 500s on /v1 only, immediately after PUT, without touching OAuth or admin" do
    put_chaos(server_error_rate: 1.0)
    expect(last_response.status).to eq(200)
    get "/v1/properties", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(500)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("chaos_injected")
    get "/admin/chaos", {}, admin
    expect(last_response.status).to eq(200)
    post "/oauth/token", grant_type: "refresh_token", refresh_token: "x", client_id: client.id, client_secret: "nope"
    expect(last_response.status).to eq(401)
    MockPms::Metrics.flush!
    get "/metrics"
    expect(last_response.body)
      .to include('mock_pms_http_requests_total{method="GET",route="/v1/{resource}",status="500"} 1')
  end

  it "does no chaos database write per request when server_error_rate is 0" do
    token
    get "/v1/properties", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(200)
    expect(MockPms.db[:chaos_counters].where(stream: "api").get(:value)).to eq(0)
  end
end
