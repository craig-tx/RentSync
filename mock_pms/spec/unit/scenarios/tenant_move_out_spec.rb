# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Scenarios::TenantMoveOut do
  let(:op) { Factory.operator }
  let!(:lease) { Factory.lease(op, start_date: Date.new(2026, 1, 1)) }

  before { freeze_time(Time.utc(2026, 10, 20, 15)) }

  it "ends one active lease early, makes the tenant former, and emits two events" do
    result = described_class.run!
    lease.refresh
    expect(lease.values).to include(status: "ended_early", actual_end_date: Date.new(2026, 10, 20))
    expect(lease.tenant.status).to eq("former")
    events = MockPms::Event.order(:seq).all
    expect(events.map(&:type)).to eq(%w[lease.updated tenant.moved_out])
    expect(events.map(&:occurred_at).uniq.size).to eq(1)
    expect(events.map(&:correlation_id).uniq).to eq([result[:run_id]])
    expect(events.map(&:source).uniq).to eq(["scenario:tenant_move_out"])
    moved_out = events.last.payload
    expect(moved_out.keys).to contain_exactly("tenant", "lease", "move_out_date")
    expect(moved_out["move_out_date"]).to eq("2026-10-20")
    expect(moved_out["lease"]["status"]).to eq("ended_early")
    expect(result).to include(scenario: "tenant_move_out", events_created: 2)
  end

  it "limits the pick to one operator when given" do
    other = Factory.operator
    Factory.lease(other)
    described_class.run!(operator_id: other.id)
    expect(lease.refresh.status).to eq("active")
  end
end
