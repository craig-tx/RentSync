# frozen_string_literal: true

require "spec_helper"

# T059, US4 AC1-AC4 and FR-023: the health page and its JSON agree, are scoped to the signed-in
# operator, show a failing reconciliation, and never show payloads, header values or tenant data.
RSpec.describe "connection health", type: :request do
  def app = Rentsync::App.build
  def base = "https://app.test"

  let(:now) { Time.utc(2026, 10, 31, 14) }
  let(:password) { "operator-password-1" }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: now },
      client_secret: "CS", signing_secret: "SS"
    )
  end

  def connect(n)
    who = Rentsync::Operator.create(email: "op#{n}@example.test", name: "Op #{n}",
                                    password_digest: Rentsync::Auth::Passwords.digest(password))
    Rentsync::PmsConnection.create(operator_id: who.id, pms_client_id: pms_client.id, pms_operator_id: "op_#{n}",
                                   pms_operator_name: "PMS #{n}", status: "active", connected_at: now - 3600,
                                   next_reconcile_at: now + 600)
  end

  let!(:ann) { connect(1) }
  let!(:bo) { connect(2) }

  before do
    freeze_time(now)
    body = JSON.generate("tenant" => "Tess Tenant-Secret")
    Rentsync.db[:raw_events].insert(
      pms_client_id: pms_client.id, connection_id: ann.id, event_id: "evt_1", event_type: "payment.created",
      occurred_at: now - 60, received_at: now - 60, arrival_path: "webhook", payload_raw: Sequel.blob(body),
      payload: Sequel.pg_jsonb_wrap(JSON.parse(body)), payload_sha256: Sequel.blob("x"), correlation_id: "corr-SECRET"
    )
    Rentsync.db[:webhook_receipts].insert(
      received_at: now - 30, connection_id: ann.id, operator_id: ann.operator_id, outcome: "rejected",
      reason: "malformed_body", event_id: "evt_bad", event_type: "payment.created", delivery_id: "dlv_HEADER-SECRET",
      body_bytes: 10, body_sha256: Sequel.blob("x"), correlation_id: "corr-SECRET"
    )
    Rentsync.db[:reconciliation_runs].insert(connection_id: ann.id, trigger: "schedule", started_at: now - 1200,
                                             finished_at: now - 1190, outcome: "succeeded", correlation_id: "r")
    Rentsync.db[:reconciliation_runs].insert(connection_id: ann.id, trigger: "schedule", started_at: now - 300,
                                             finished_at: now - 290, outcome: "failed",
                                             error_code: "pms_unavailable", correlation_id: "r")
    post "#{base}/sign-in", email: "op1@example.test", password: password
  end

  def page(con) = get("#{base}/connections/#{con.public_id}/health")
  def json(path) = get("#{base}#{path}", {}, { "HTTP_ACCEPT" => "application/json" })

  it "serves the same report as HTML and as JSON" do
    expected = JSON.parse(JSON.generate(Rentsync::Health::Report.new(ann).to_h))
    json("/v1/connections/#{ann.public_id}/health")
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq(expected)
    json("/connections/#{ann.public_id}/health")
    expect(JSON.parse(last_response.body)).to eq(expected)

    page(ann)
    expect(last_response.status).to eq(200)
    html = last_response.body
    expect(html).to include("PMS 1", "active", "malformed_body", "evt_bad")
    expect(html).to match(%r{Events received</th>\s*<td>1</td>})
    expect(html).to match(%r{Rejected \(90 days\)</th>\s*<td>1</td>})
  end

  it "says when reconciliation is failing, with the error and the last success (AC3)" do
    page(ann)
    expect(last_response.body).to include("pms_unavailable", "Last succeeded")
    expect(last_response.body).to include("2026-10-31 13:40 UTC")
  end

  it "never shows payload content, header values, correlation IDs or tenant data (AC2)" do
    page(ann)
    expect(last_response.body).not_to include("Tess Tenant-Secret", "dlv_HEADER-SECRET", "corr-SECRET")
  end

  it "gives another operator's connection 404, as HTML and JSON (AC4, FR-023)" do
    page(bo)
    expect(last_response.status).to eq(404)
    json("/v1/connections/#{bo.public_id}/health")
    expect(last_response.status).to eq(404)
    expect(last_response.body).not_to include("PMS 2")
  end

  it "needs a session: the page redirects to sign-in, the JSON answers 401" do
    post "#{base}/sign-out", csrf_token: csrf
    page(ann)
    expect(last_response.status).to eq(303)
    json("/v1/connections/#{ann.public_id}/health")
    expect(last_response.status).to eq(401)
  end

  it "links each connection to its health page, and Reconcile now returns there" do
    get "#{base}/connections"
    expect(last_response.body).to include("/connections/#{ann.public_id}/health")
    post "#{base}/connections/#{ann.public_id}/reconcile", csrf_token: csrf
    expect(last_response.location).to include("/connections/#{ann.public_id}/health?result=reconcile_requested")
  end

  def csrf
    get "#{base}/connections"
    last_response.body[/name="csrf_token" value="([^"]+)"/, 1]
  end
end
