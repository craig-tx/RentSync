# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Pagination do
  let(:operator) { Factory.operator }

  before { 120.times { Factory.tenant(operator) } }

  def dataset = MockPms::Tenant.where(operator_seq: operator.seq)

  it "round-trips cursors as URL-safe base64 of the last seq" do
    rows, cursor = described_class.paginate(dataset, limit: 50, cursor: nil)
    expect(rows.size).to eq(50)
    expect(Base64.urlsafe_decode64(cursor).to_i).to eq(rows.last.seq)
  end

  it "defaults limit to 50 and returns nil next_cursor on the last page" do
    _, cursor = described_class.paginate(dataset, limit: nil, cursor: nil)
    _, cursor = described_class.paginate(dataset, limit: nil, cursor: cursor)
    rows, cursor = described_class.paginate(dataset, limit: nil, cursor: cursor)
    expect(rows.size).to eq(20)
    expect(cursor).to be_nil
  end

  it "rejects limit outside 1..200 and malformed cursors" do
    [0, 201, "abc"].each do |bad|
      expect { described_class.paginate(dataset, limit: bad, cursor: nil) }.to raise_error(MockPms::Pagination::Invalid)
    end
    expect { described_class.paginate(dataset, limit: 10, cursor: "!!not-base64") }
      .to raise_error(MockPms::Pagination::Invalid)
  end

  it "never skips or repeats rows that existed when paging began, even with inserts" do
    original = dataset.select_order_map(:seq)
    seen = []
    cursor = nil
    loop do
      rows, cursor = described_class.paginate(dataset, limit: 50, cursor: cursor)
      seen.concat(rows.map(&:seq))
      Factory.tenant(operator) if seen.size == 50
      break if cursor.nil?
    end
    expect(seen & original).to eq(original)
    expect(seen.uniq.size).to eq(seen.size)
    expect(seen.size).to eq(original.size + 1)
  end

  it "narrows with updated_since without changing seq order" do
    cutoff = Time.now.utc - 3600
    old = MockPms::Tenant.where(operator_seq: operator.seq).order(:seq).limit(10).select_map(:seq)
    MockPms::Tenant.where(seq: old).update(updated_at: cutoff - 60)
    rows, = described_class.paginate(dataset.where { updated_at >= cutoff }, limit: 200, cursor: nil)
    expect(rows.size).to eq(110)
    expect(rows.map(&:seq)).to eq(rows.map(&:seq).sort)
  end
end
