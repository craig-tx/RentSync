# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Rentsync middleware" do
  let(:io) { StringIO.new }
  let(:seen) { [] }
  let(:inner) do
    lambda do |env|
      seen << Thread.current[:correlation_id]
      [env["PATH_INFO"] == "/boom" ? 500 : 200, {}, ["ok"]]
    end
  end

  around do |example|
    original = Rentsync::Logging.io
    Rentsync::Logging.io = io
    example.run
  ensure
    Rentsync::Logging.io = original
  end

  def env_for(path, headers = {}) = Rack::MockRequest.env_for(path, headers)

  describe Rentsync::Middleware::CorrelationId do
    subject(:app) { described_class.new(inner) }

    it "takes the caller's X-Correlation-Id, exposes it while handling, and echoes it" do
      _, headers, = app.call(env_for("/healthz", "HTTP_X_CORRELATION_ID" => "corr-pms-1"))
      expect(seen).to eq(["corr-pms-1"])
      expect(headers["x-correlation-id"]).to eq("corr-pms-1")
      expect(Thread.current[:correlation_id]).to be_nil
    end

    it "prefers X-Correlation-Id to X-Request-Id, so a proxy's request ID never replaces the PMS's" do
      _, headers, = app.call(env_for("/healthz", "HTTP_X_REQUEST_ID" => "req-proxy",
                                                 "HTTP_X_CORRELATION_ID" => "corr-pms-1"))
      expect(seen).to eq(["corr-pms-1"])
      expect(headers["x-correlation-id"]).to eq("corr-pms-1")
    end

    it "generates one when none is given" do
      _, headers, = app.call(env_for("/healthz"))
      expect(headers["x-correlation-id"]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it "writes one access-log line with a bounded route label, never the raw path" do
      app.call(env_for("/connections/con_SECRETISH123/health"))
      line = JSON.parse(io.string.lines.last)
      expect(line).to include("body" => "request", "http.response.status_code" => 200,
                              "url.path" => "/connections/{page}")
      expect(io.string).not_to include("con_SECRETISH123")
    end
  end

  describe Rentsync::Middleware::RequestMetrics do
    subject(:app) { described_class.new(inner) }

    it "counts requests and observes latency by route, method and status" do
      app.call(env_for("/webhooks/pms", method: "POST"))
      app.call(env_for("/boom"))
      deltas = Rentsync::Metrics.buffer.swap!
      requests = deltas[:counters].fetch("rentsync_http_requests_total")
      expect(requests).to include("method=POST|route=/webhooks/{source}|status=200" => 1,
                                  "method=GET|route=unmatched|status=500" => 1)
      expect(deltas[:histograms]).to have_key("rentsync_http_request_duration_seconds")
    end
  end
end
