# frozen_string_literal: true

require "spec_helper"

# T035: connection attempts older than 7 days are purged once a day, by whichever worker holds
# the daily_purge lease.
RSpec.describe Rentsync::Jobs::DailyPurge do
  let(:operator) { Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x") }
  let(:now) { Time.utc(2026, 10, 29, 3) }

  def attempt(age_s)
    created = now - age_s
    Rentsync.db[:connection_attempts].insert(operator_id: operator.id, created_at: created, expires_at: created + 600,
                                             state_sha256: Sequel.blob(SecureRandom.bytes(32)))
  end

  def ages = Rentsync.db[:connection_attempts].select_map(:created_at).map { |t| (now - t).round }.sort

  before { freeze_time(now) }

  it "deletes attempts older than 7 days and keeps the rest" do
    attempt((7 * 86_400) + 1)
    attempt(30 * 86_400)
    attempt((7 * 86_400) - 60)
    attempt(60)
    expect(described_class.new.run_once).to eq(2)
    expect(ages).to eq([60, (7 * 86_400) - 60])
  end

  describe "webhook receipts (T054)" do
    def receipt(age_s)
      Rentsync.db[:webhook_receipts].insert(received_at: now - age_s, outcome: "rejected", reason: "bad_signature",
                                            body_bytes: 1, body_sha256: Sequel.blob("x"), correlation_id: "c")
    end

    def raw_event(age_s)
      client = Rentsync::PmsClient.create_with_secrets(
        { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: now },
        client_secret: "CS", signing_secret: "SS"
      )
      con = Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: client.id, pms_operator_id: "op_1",
                                           pms_operator_name: "PMS", status: "active")
      Rentsync.db[:raw_events].insert(
        pms_client_id: client.id, connection_id: con.id, event_id: "evt_old", event_type: "lease.updated",
        occurred_at: now - age_s, received_at: now - age_s, arrival_path: "webhook", payload_raw: Sequel.blob("{}"),
        payload: Sequel.pg_jsonb_wrap({}), payload_sha256: Sequel.blob("x"), correlation_id: "c"
      )
    end

    it "deletes receipts older than 90 days and never touches raw events" do
      raw_event(400 * 86_400)
      receipt((90 * 86_400) + 1)
      receipt((90 * 86_400) - 60)
      expect(described_class.new.run_once).to eq(1)
      expect(Rentsync.db[:webhook_receipts].count).to eq(1)
      expect(Rentsync.db[:raw_events].count).to eq(1)
    end

    it "runs once a day across two workers" do
      receipt(100 * 86_400)
      expect(described_class.new.run_once).to eq(1)
      receipt(100 * 86_400)
      expect(described_class.new.run_once).to eq(0)
      advance(86_400)
      expect(described_class.new.run_once).to eq(1)
    end
  end

  it "runs at most once a day" do
    described_class.new.run_once
    attempt(8 * 86_400)
    advance(23 * 3600)
    expect(described_class.new.run_once).to eq(0)
    expect(ages.size).to eq(1)
    advance(3600)
    expect(described_class.new.run_once).to eq(1)
  end

  it "does nothing while another worker holds the lease" do
    attempt(8 * 86_400)
    Rentsync.db[:maintenance_leases].insert(name: "daily_purge", lease_until: now + 60, last_run_at: nil)
    expect(described_class.new.run_once).to eq(0)
    advance(61)
    expect(described_class.new.run_once).to eq(1)
  end

  it "records the run and releases the lease" do
    described_class.new.run_once
    row = Rentsync.db[:maintenance_leases].first(name: "daily_purge")
    expect(row[:last_run_at]).to eq(now)
    expect(row[:lease_until]).to be_nil
  end

  it "is one of the worker's jobs" do
    expect(Rentsync::Worker.jobs.map(&:class)).to include(described_class)
  end
end
