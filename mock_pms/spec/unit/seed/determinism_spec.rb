# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Seed::Generator do
  let(:anchor) { Date.new(2026, 10, 20) }

  def run(seed) = MockPms::Seed::Reset.run!(seed: seed, anchor_date: anchor)

  it "produces identical digests for the same seed and anchor, different for another seed", :slow do
    first = run(42)
    second = run(42)
    other = run(7)
    expect(first[:data_digest]).to eq(second[:data_digest])
    expect(other[:data_digest]).not_to eq(first[:data_digest])
  end

  it "seeds within 60 s (SC-002)", :slow do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run(42)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 60
  end

  it "excludes seq, password_digest and OAuth/delivery/harness tables from the digest" do
    run(42)
    dump = MockPms::Seed::Digest.canonical_dump
    expect(dump).not_to include("password_digest")
    expect(dump).not_to match(/"seq"/)
    before = MockPms::Seed::Digest.compute
    Factory.client
    MockPms.db[:worker_heartbeats].insert(worker_id: "x", beat_at: Time.now.utc)
    expect(MockPms::Seed::Digest.compute).to eq(before)
  end

  describe "profile" do
    # Seed once for the group (committed); each example still runs in a rolled-back transaction.
    before(:context) { MockPms::Seed::Reset.run!(seed: 42, anchor_date: Date.new(2026, 10, 20)) }
    after(:context) { DbSupport.truncate_all! }

    let(:end_of_anchor) { Time.utc(anchor.year, anchor.month, anchor.day, 23, 59, 59) }

    it "has 3 operators with about 25/15/10 properties and 60 leases" do
      expect(MockPms::Operator.count).to eq(3)
      counts = MockPms::Property.group_and_count(:operator_seq).map { |r| r[:count] }.sort
      expect(counts).to eq([10, 15, 25])
      expect(MockPms::Lease.count).to eq(60)
    end

    it "has at least 3 ended_early leases with no rent charge after actual_end_date" do
      early = MockPms::Lease.where(status: "ended_early").all
      expect(early.size).to be >= 3
      early.each do |lease|
        expect(lease.actual_end_date).to be < lease.scheduled_end_date
        expect(MockPms::Charge.where(lease_seq: lease.seq, kind: "rent") do
          period > lease.actual_end_date
        end.count).to eq(0)
      end
    end

    it "covers the 12 months ending with the anchor month" do
      periods = MockPms::Charge.where(kind: "rent").distinct.select_order_map(:period)
      expect(periods.first).to eq(Date.new(2025, 11, 1))
      expect(periods.last).to eq(Date.new(2026, 10, 1))
      expect(periods.size).to eq(12)
    end

    it "contains every payment-behavior category" do
      stats = MockPms::Seed::Report.behaviors
      expect(stats.fetch(:on_time)).to be_positive
      [3, 7, 12].each { |d| expect(stats.fetch(:late_days)).to include(d) }
      expect(stats.fetch(:late_days).max).to be >= 20
      expect(stats.fetch(:partial_completed)).to be_positive
      expect(stats.fetch(:partial_never_completed)).to be_positive
      expect(stats.fetch(:nsf_reversed)).to be_positive
      expect(stats.fetch(:unpaid)).to be_positive
    end

    it "includes an NSF reversal of a partial payment, reversed for its full amount" do
      partial_reversals = MockPms.db[:reversals].join(:payments, seq: :payment_seq)
                                 .join(:payment_applications, payment_seq: :seq)
                                 .join(:charges, seq: :charge_seq)
                                 .where(Sequel[:reversals][:reason] => "nsf")
                                 .where { Sequel[:payments][:amount_cents] < Sequel[:charges][:amount_cents] }
                                 .select(Sequel[:reversals][:amount_cents].as(:rev),
                                         Sequel[:payments][:amount_cents].as(:pay))
                                 .all
      expect(partial_reversals).not_to be_empty
      partial_reversals.each { |r| expect(r[:rev]).to eq(r[:pay]) }
    end

    it "reverses every reversed payment for its full amount" do
      MockPms::Reversal.each do |reversal|
        expect(reversal.amount_cents).to eq(MockPms::Payment[reversal.payment_seq].amount_cents)
      end
    end

    it "never timestamps seeded rows after the anchor date" do
      %i[operators properties tenants leases charges payments reversals].each do |table|
        expect(MockPms.db[table].max(:created_at)).to be <= end_of_anchor
      end
    end
  end
end
