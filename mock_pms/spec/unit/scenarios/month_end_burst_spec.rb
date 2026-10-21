# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Scenarios::MonthEndBurst do
  let(:now) { Time.utc(2026, 10, 30, 18) }
  let(:op) { Factory.operator }
  let(:other) { Factory.operator }
  let!(:leases) { Array.new(10) { Factory.lease(op, start_date: Date.new(2026, 1, 1)) } }

  before { freeze_time(now) }

  it "pays next month's rent for ceil(share × active leases), spread across the window before now" do
    result = described_class.run!(share: 0.8, window_s: 120)
    payments = MockPms::Payment.order(:received_at).all
    expect(payments.size).to eq(8)
    expect(payments.map(&:received_at).minmax).to eq([now - 120, now - (120.0 / 8)])
    payments.each do |payment|
      charge = payment.applications.first.charge
      expect(charge.values).to include(kind: "rent", period: Date.new(2026, 11, 1))
      expect(payment.applications.sum(&:amount_cents)).to eq(charge.amount_cents)
    end
    expect(result).to include(scenario: "month_end_burst", events_created: 8)
    events = MockPms::Event.where(type: "payment.created").order(:occurred_at).all
    expect(events.map(&:occurred_at)).to eq(payments.map(&:received_at))
  end

  it "defaults share to 0.8, meeting SC-008's 70% minimum" do
    described_class.run!
    expect(MockPms::Payment.count).to eq(8)
  end

  it "limits the burst to one operator when operator_id is given" do
    Factory.lease(other)
    described_class.run!(operator_id: other.id, share: 1.0)
    expect(MockPms::Payment.select_map(:operator_seq).uniq).to eq([other.seq])
  end

  it "pays the following period on a repeat run instead of double-paying" do
    described_class.run!(share: 1.0)
    described_class.run!(share: 1.0)
    periods = MockPms::Charge.where(kind: "rent").select_map(:period).uniq.sort
    expect(periods).to eq([Date.new(2026, 11, 1), Date.new(2026, 12, 1)])
  end
end
