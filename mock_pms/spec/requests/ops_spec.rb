# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ops endpoints", type: :request do
  def app = MockPms::App.build

  def beat!(age_s)
    MockPms.db[:worker_heartbeats].insert_conflict(target: :worker_id, update: { beat_at: Sequel[:excluded][:beat_at] })
           .insert(worker_id: "w1", beat_at: Time.now.utc - age_s)
  end

  describe "GET /healthz" do
    it "is 200 when db, redis and a fresh worker heartbeat are present" do
      beat!(3)
      get "/healthz"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to include("status" => "ok", "db" => "ok", "redis" => "ok")
      expect(body["worker_heartbeat_age_s"]).to be_between(0, 30)
    end

    it "is 503 with redis down when Redis is unreachable" do
      beat!(1)
      allow(MockPms::Redis).to receive(:ping?).and_return(false)
      get "/healthz"
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body)).to include("redis" => "down")
    end

    it "is 503 when the worker heartbeat is missing" do
      get "/healthz"
      expect(last_response.status).to eq(503)
    end

    it "is 503 when the worker heartbeat is older than 30 s" do
      beat!(45)
      get "/healthz"
      expect(last_response.status).to eq(503)
    end
  end

  describe "GET /metrics" do
    it "renders Prometheus text with flushed request counters and target_info" do
      beat!(1)
      get "/healthz"
      MockPms::Metrics.flush!
      get "/metrics"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("text/plain")
      expect(last_response.content_type).to include("version=0.0.4")
      expected = 'mock_pms_http_requests_total{method="GET",route="/healthz",status="200"} 1'
      expect(last_response.body).to include(expected)
      expect(last_response.body).to match(
        /^target_info\{deployment_environment="[^"]+",service_name="mock_pms-web",service_version="[^"]+"\} 1$/
      )
    end
  end

  it "returns the error envelope for an unknown route" do
    get "/nope"
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body)).to match("error" => hash_including("code" => "not_found",
                                                                              "message" => String))
  end

  it "echoes X-Request-Id as X-Correlation-Id" do
    get "/healthz", {}, { "HTTP_X_REQUEST_ID" => "abc" }
    expect(last_response.headers["X-Correlation-Id"]).to eq("abc")
  end

  it "generates a correlation id when none is sent" do
    get "/healthz"
    expect(last_response.headers["X-Correlation-Id"]).to match(/\A[0-9a-f-]{36}\z/)
  end
end
