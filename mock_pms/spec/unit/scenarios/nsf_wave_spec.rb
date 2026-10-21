# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Scenarios::NsfWave do
  let(:op) { Factory.operator }
  let(:lease) { Factory.lease(op) }

  before do
    freeze_time(Time.utc(2026, 10, 20, 15))
    [1, 2, 3].each { |d| Factory.payment(lease, received_at: Time.utc(2026, 10, d, 10)) }
  end

  it "reverses the most recent settled payments in full and emits payment.reversed" do
    result = described_class.run!(count: 2)
    reversed = MockPms::Payment.where(status: "reversed").order(:received_at).all
    expect(reversed.map { |p| p.received_at.day }).to eq([2, 3])
    reversed.each do |p|
      expect(p.reversal.values).to include(reason: "nsf", amount_cents: p.amount_cents)
    end
    events = MockPms::Event.where(type: "payment.reversed").all
    expect(events.size).to eq(2)
    expect(events.map { |e| e.payload["status"] }.uniq).to eq(["reversed"])
    expect(events.map { |e| e.payload.dig("reversal", "reason") }.uniq).to eq(["nsf"])
    expect(events.map(&:correlation_id).uniq).to eq([result[:run_id]])
    expect(result).to include(scenario: "nsf_wave", events_created: 2, counts: { "payments_reversed" => 2 })
  end
end
