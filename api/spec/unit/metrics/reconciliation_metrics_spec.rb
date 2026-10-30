# frozen_string_literal: true

require "spec_helper"

# T056, research R16: reconciliation runs, PMS requests, rate-limit waits and token renewals are
# counted, with labels from fixed lists.
RSpec.describe "reconciliation metrics" do
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end

  def connection(expires_at: Time.now.utc - 1)
    operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
    Rentsync::PmsConnection.create_with_secrets(
      { operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1", pms_operator_name: "PMS",
        status: "active", access_expires_at: expires_at },
      access_token: "AT-OLD", refresh_token: "RT-OLD"
    )
  end

  def counters(family) = Rentsync::Metrics.buffer.swap![:counters].fetch(family, {})

  it "registers the families so /metrics renders them" do
    expect(Rentsync::Metrics::FAMILIES.keys).to include(
      "rentsync_reconciliation_runs_total", "rentsync_pms_requests_total",
      "rentsync_pms_rate_limit_waits_seconds_total", "rentsync_token_renewals_total"
    )
  end

  describe "rentsync_token_renewals_total" do
    def renew(status, body)
      Rentsync::Pms::Renewal.new(request: ->(_req, _uri) { [status, body] }).access_token!(connection)
    rescue Rentsync::Pms::Renewal::NeedsReauth, Rentsync::Pms::Renewal::Unavailable
      nil
    end

    it "counts a renewal" do
      renew(200, JSON.generate(access_token: "AT", token_type: "Bearer", expires_in: 300, refresh_token: "RT",
                               scope: "read", operator_id: "op_1", operator_name: "PMS"))
      expect(counters("rentsync_token_renewals_total")).to eq("result=renewed" => 1)
    end

    it "counts a refusal as needs_reauth" do
      renew(400, JSON.generate(error: "invalid_grant"))
      expect(counters("rentsync_token_renewals_total")).to eq("result=needs_reauth" => 1)
    end

    it "counts anything else as failed" do
      renew(503, "")
      expect(counters("rentsync_token_renewals_total")).to eq("result=failed" => 1)
    end
  end

  it "counts reconciliation runs by result" do
    con = connection(expires_at: Time.now.utc + 3600)
    client = instance_double(Rentsync::Pms::Client, rate_limit_waits: 0, rate_limit_wait_s: 0.0)
    allow(client).to receive(:get).and_return({ "data" => [], "next_cursor" => nil })
    Rentsync::Reconciliation::Run.new(con, client: client).perform!(trigger: "schedule")
    allow(client).to receive(:get).and_raise(Rentsync::Pms::Client::Failed.new(503))
    Rentsync::Reconciliation::Run.new(con.refresh, client: client).perform!(trigger: "schedule")
    expect(counters("rentsync_reconciliation_runs_total")).to eq("result=succeeded" => 1, "result=failed" => 1)
  end
end
