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

    # Feature 002 FR-028: the release check reads the build and the deployment from /healthz.
    it "reports version and deployment_id on 200" do
      beat!(1)
      get "/healthz"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to include("version" => MockPms::Settings.service_version,
                                                        "deployment_id" => MockPms::Settings.deployment_id)
    end

    it "reports version and deployment_id on 503" do
      get "/healthz"
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body)).to include("version" => MockPms::Settings.service_version,
                                                        "deployment_id" => MockPms::Settings.deployment_id)
    end

    # The server's current time, so a reader can tell the answer is fresh; and when this process
    # started, which dates the last deploy or restart.
    it "reports the current time and when the process started, in ISO 8601 UTC" do
      beat!(1)
      freeze_time(Time.utc(2026, 10, 27, 12, 0, 5))
      get "/healthz"
      body = JSON.parse(last_response.body)
      expect(body["time"]).to eq("2026-10-27T12:00:05Z")
      expect(body["started_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
      expect(Time.iso8601(body["started_at"])).to be <= Time.now.utc
    end

    it "repeats both times in US Central time, for readers who don't think in UTC" do
      beat!(1)
      freeze_time(Time.utc(2026, 10, 27, 12, 0, 5))
      get "/healthz"
      body = JSON.parse(last_response.body)
      expect(body["time_ct"]).to eq("2026-10-27 07:00:05 CDT")
      expect(body["started_at_ct"]).to eq(MockPms::CentralTime.format(Time.iso8601(body["started_at"])))
    end

    it "keeps started_at fixed while the time moves on" do
      beat!(1)
      get "/healthz"
      first = JSON.parse(last_response.body)
      freeze_time(Time.now.utc + 60)
      get "/healthz"
      second = JSON.parse(last_response.body)
      expect(second["started_at"]).to eq(first["started_at"])
      expect(Time.iso8601(second["time"])).to be > Time.iso8601(first["time"])
    end

    it "reports the time and started_at on 503 too" do
      get "/healthz"
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).keys).to include("time", "started_at")
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

  describe "GET /healthz/live" do
    it "reports status, version, deployment_id, the time and when the process started" do
      freeze_time(Time.utc(2026, 10, 27, 12, 0, 5))
      get "/healthz/live"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.except("started_at", "started_at_ct"))
        .to eq("status" => "ok", "version" => MockPms::Settings.service_version,
               "deployment_id" => MockPms::Settings.deployment_id,
               "time" => "2026-10-27T12:00:05Z", "time_ct" => "2026-10-27 07:00:05 CDT")
      expect(body["started_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
      expect(body["started_at_ct"]).to match(/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d C[DS]T\z/)
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
      labels = 'deployment_environment="[^"]+",deployment_id="[^"]+",' \
               'service_name="mock_pms-web",service_version="[^"]+"'
      expect(last_response.body).to match(/^target_info\{#{labels}\} 1$/)
    end
  end

  it "includes database-backed delivery metrics" do
    beat!(2)
    get "/metrics"
    expect(last_response.body).to include("mock_pms_delivery_queue_depth 0", "mock_pms_worker_heartbeat_age_seconds")
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
