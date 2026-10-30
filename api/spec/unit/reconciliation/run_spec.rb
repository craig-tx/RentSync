# frozen_string_literal: true

require "spec_helper"

# T048, research R4 and R5, data-model.md reconciliation_runs: a resumable walk of
# /v1/payments that records each payment and reversal once, whichever path saw it first.

# Stands in for a process being killed: not a StandardError, so nothing rescues it.
class ReconciliationKilled < Exception; end # rubocop:disable Lint/InheritException

RSpec.describe Rentsync::Reconciliation::Run do
  before(:context) { @pms = FakePms.new.start }
  after(:context) { @pms.stop }

  let(:pms) { @pms }
  let(:now) { Time.utc(2026, 10, 31, 14) }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end
  let(:connection) do
    operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
                                   pms_operator_name: "Lone Star Rentals", status: "active",
                                   access_expires_at: now + 3600)
  end
  let(:renewal) { double("renewal", access_token!: "AT-1") }

  def payment(id, received_at: "2026-10-01T15:00:00Z", reversed_at: nil)
    { "id" => id, "lease_id" => "lea_1", "amount_cents" => 125_000, "received_at" => received_at, "method" => "ach",
      "status" => reversed_at ? "reversed" : "settled", "applied_to" => [],
      "reversal" => reversed_at && { "id" => "rev_#{id}", "reason" => "nsf", "reversed_at" => reversed_at } }
  end

  let(:first_page) { [payment("pay_1"), payment("pay_2", reversed_at: "2026-10-05T09:00:00Z")] }
  let(:second_page) { [payment("pay_3", received_at: "2026-10-20T15:00:00Z")] }

  # Two pages; the second can be replaced, e.g. by a kill.
  def script_pages(second: nil)
    pms.script(lambda do |req|
      if req.query["cursor"] == "c1"
        second ? second.call : [200, {}, { data: second_page, next_cursor: nil }]
      else
        [200, {}, { data: first_page, next_cursor: "c1" }]
      end
    end)
  end

  def run(trigger: "schedule", random: -> { 1.0 }, kill_at: nil)
    client = Rentsync::Pms::Client.new(connection.refresh, base_url: pms.base_url, renewal: renewal,
                                                           sleeper: ->(_) {}, random: random)
    if kill_at
      allow(client).to receive(:get).and_wrap_original do |original, path, params|
        raise ReconciliationKilled if params[:cursor] == kill_at

        original.call(path, params)
      end
    end
    described_class.new(connection.refresh, client: client, random: random).perform!(trigger: trigger)
  end

  def raw_events = Rentsync.db[:raw_events]
  def runs = Rentsync.db[:reconciliation_runs].order(:id)
  def facts = raw_events.order(:event_id).select_map(%i[event_id business_key event_type occurred_at arrival_path])

  before do
    pms.requests.clear
    freeze_time(now)
    script_pages
  end

  it "backfills fully on the first run: no updated_since, trigger initial" do
    run(trigger: "manual")
    expect(pms.requests.map(&:query)).to eq([{ "limit" => "200" }, { "limit" => "200", "cursor" => "c1" }])
    expect(runs.first).to include(trigger: "initial", outcome: "succeeded", window_from: nil, pages: 2,
                                  payments_seen: 3, facts_added: 4, started_at: now, finished_at: now)
  end

  it "records each payment, plus its reversal, as reconciled facts with synthetic IDs" do
    run
    reversal = raw_events.first(event_id: "recon:payment.reversed:pay_2")
    expect(facts).to eq([
                          ["recon:payment.created:pay_1", "payment.created:pay_1", "payment.created",
                           Time.utc(2026, 10, 1, 15), "reconciliation"],
                          ["recon:payment.created:pay_2", "payment.created:pay_2", "payment.created",
                           Time.utc(2026, 10, 1, 15), "reconciliation"],
                          ["recon:payment.created:pay_3", "payment.created:pay_3", "payment.created",
                           Time.utc(2026, 10, 20, 15), "reconciliation"],
                          ["recon:payment.reversed:pay_2", "payment.reversed:pay_2", "payment.reversed",
                           Time.utc(2026, 10, 5, 9), "reconciliation"]
                        ])
    expect(reversal).to include(received_at: now, connection_id: connection.id, reconciliation_run_id: runs.first[:id],
                                correlation_id: runs.first[:correlation_id])
    expect(JSON.parse(reversal[:payload_raw])).to eq(first_page.last)
    expect(reversal[:payload_sha256]).to eq(Digest::SHA256.digest(reversal[:payload_raw]))
  end

  it "adds nothing a webhook already recorded, and nothing on a second identical run" do
    body = JSON.generate("id" => "evt_1", "type" => "payment.created", "data" => { "object" => first_page.first })
    raw_events.insert(pms_client_id: pms_client.id, connection_id: connection.id, event_id: "evt_1",
                      business_key: "payment.created:pay_1", event_type: "payment.created", occurred_at: now,
                      received_at: now, arrival_path: "webhook", payload_raw: Sequel.blob(body),
                      payload: Sequel.pg_jsonb_wrap(JSON.parse(body)),
                      payload_sha256: Sequel.blob(Digest::SHA256.digest(body)), correlation_id: "c")
    run
    expect(runs.last[:facts_added]).to eq(3)
    expect(raw_events.where(business_key: "payment.created:pay_1").count).to eq(1)
    advance(60)
    run
    expect(runs.last).to include(outcome: "succeeded", facts_added: 0)
    expect(raw_events.count).to eq(4)
  end

  it "asks later runs for the window since the watermark minus the overlap" do
    run
    expect(connection.refresh).to have_attributes(reconcile_watermark: now, reconcile_cursor: nil,
                                                  next_reconcile_at: now + Rentsync::Settings.reconcile_interval_s)
    advance(900)
    pms.requests.clear
    run
    since = (now - Rentsync::Settings.reconcile_overlap_s).iso8601
    expect(pms.requests.first.query).to eq("limit" => "200", "updated_since" => since)
    expect(runs.last).to include(trigger: "schedule", window_from: now - Rentsync::Settings.reconcile_overlap_s)
    expect(connection.refresh.reconcile_watermark).to eq(now + 900)
  end

  it "saves the cursor after each page, and a killed run is resumed and ends like a clean run" do
    expect { run(kill_at: "c1") }.to raise_error(ReconciliationKilled)
    expect(connection.refresh.reconcile_cursor).to eq("c1")
    expect(runs.first[:outcome]).to be_nil
    expect(raw_events.count).to eq(3)

    script_pages
    pms.requests.clear
    advance(600)
    run
    expect(runs.first).to include(outcome: "failed", error_code: "interrupted")
    expect(pms.requests.map { |r| r.query["cursor"] }).to eq(["c1"])
    expect(runs.last).to include(outcome: "succeeded", facts_added: 1)
    expect(facts.map(&:first)).to eq(%w[recon:payment.created:pay_1 recon:payment.created:pay_2
                                        recon:payment.created:pay_3 recon:payment.reversed:pay_2])
    # The watermark is the interrupted walk's start, so nothing updated between the two is skipped.
    expect(connection.refresh).to have_attributes(reconcile_watermark: now, reconcile_cursor: nil)
  end

  it "keeps the cursor on failure and backs off 30 s doubling up to the interval" do
    script_pages(second: -> { [503, {}, {}] })
    run
    expect(runs.first).to include(outcome: "failed", error_code: "pms_unavailable", pages: 1)
    con = connection.refresh
    expect(con).to have_attributes(reconcile_cursor: "c1", reconcile_failures: 1, reconcile_watermark: nil,
                                   next_reconcile_at: now + 30, reconcile_lease_until: nil)
    delays = (2..7).map do |n|
      described_class.backoff_s(n, 1.0)
    end
    expect(delays).to eq([60, 120, 240, 480, 900, 900])
    expect(described_class.backoff_s(1, 0.0)).to eq(15)
  end

  it "honours a Reconcile now pressed during the run, and clears one that the run covered" do
    connection.this.update(reconcile_requested_at: now - 10)
    run
    expect(connection.refresh).to have_attributes(reconcile_requested_at: nil,
                                                  next_reconcile_at: now + Rentsync::Settings.reconcile_interval_s)
    connection.this.update(reconcile_requested_at: now + 5)
    run
    expect(connection.refresh).to have_attributes(next_reconcile_at: now)
    expect(connection.reconcile_requested_at).not_to be_nil
  end

  it "records a refusal to renew as needs_reauth" do
    allow(renewal).to receive(:access_token!).and_raise(Rentsync::Pms::Renewal::NeedsReauth)
    run
    expect(runs.first).to include(outcome: "failed", error_code: "needs_reauth")
  end

  it "counts reconciled facts by type" do
    run
    counters = Rentsync::Metrics.buffer.swap![:counters]["rentsync_raw_events_total"]
    expect(counters).to include("arrival_path=reconciliation|type=payment.created" => 3,
                                "arrival_path=reconciliation|type=payment.reversed" => 1)
  end
end
