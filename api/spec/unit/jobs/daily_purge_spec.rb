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
