# frozen_string_literal: true

require "spec_helper"

RSpec.describe "per-client rate limiting", type: :request do
  def app = MockPms::App.build

  let(:op) { Factory.operator }
  let(:client) { Factory.client(rate_limit_per_minute: 3).first }
  let(:token) { Factory.tokens(client, op).last[:access_token] }
  let(:auth) { { "HTTP_AUTHORIZATION" => "Bearer #{token}" } }
  let(:admin) { { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}" } }

  before { Factory.lease(op) }

  it "answers the request over the limit with 429, the envelope, and Retry-After" do
    3.times do
      get "/v1/properties", {}, auth
      expect(last_response.status).to eq(200)
    end
    get "/v1/properties", {}, auth
    expect(last_response.status).to eq(429)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("rate_limited")
    expect(Integer(last_response.headers["Retry-After"])).to be >= 1
  end

  it "never limits oauth, admin, health or metrics endpoints" do
    3.times { get "/v1/properties", {}, auth }
    5.times do
      get "/healthz/live"
      expect(last_response.status).to eq(200)
      get "/metrics"
      expect(last_response.status).to eq(200)
      get "/admin/status", {}, admin
      expect(last_response.status).to eq(200)
      get "/oauth/authorize", { response_type: "code", client_id: client.id, redirect_uri: client.redirect_uris.first }
      expect(last_response.status).to eq(200)
    end
  end

  it "does not spend tokens on scenario activity" do
    MockPms::Scenarios::TenantMoveOut.run!
    3.times do
      get "/v1/properties", {}, auth
      expect(last_response.status).to eq(200)
    end
  end

  it "fails closed with 503 when Redis is unreachable" do
    token
    allow(MockPms::RateLimit::Limiter).to receive(:check).and_raise(Redis::CannotConnectError)
    get "/v1/properties", {}, auth
    expect(last_response.status).to eq(503)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("rate_limiter_unavailable")
  end

  it "answers invalid or expired tokens with 401 without spending a token" do
    3.times do
      get "/v1/properties", {}, { "HTTP_AUTHORIZATION" => "Bearer nope" }
      expect(last_response.status).to eq(401)
    end
    get "/v1/properties", {}, auth
    expect(last_response.status).to eq(200)
  end

  it "labels 429s with the fallback route, never the raw path" do
    4.times { get "/v1/properties", {}, auth }
    MockPms::Metrics.flush!
    get "/metrics"
    expect(last_response.body)
      .to include('mock_pms_http_requests_total{method="GET",route="/v1/{resource}",status="429"} 1')
    expect(last_response.body).to include("mock_pms_rate_limited_total{client_id=\"#{client.id}\"} 1")
  end
end
