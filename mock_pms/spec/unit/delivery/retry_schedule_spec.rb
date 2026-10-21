# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Delivery::RetrySchedule do
  it "doubles from the base with no jitter: 2, 4, 8, 16, 32, 64, 128" do
    schedule = described_class.new(base: 2, max_attempts: 8, jitter: -> { 0.0 })
    expect((1..7).map { |n| schedule.next_delay(n) }).to eq([2, 4, 8, 16, 32, 64, 128])
  end

  it "keeps jitter within ±10%" do
    schedule = described_class.new(base: 2, max_attempts: 8)
    200.times do
      delay = schedule.next_delay(3)
      expect(delay).to be_between(8 * 0.9, 8 * 1.1)
    end
  end

  it "returns nil after the last attempt so the delivery is exhausted" do
    schedule = described_class.new(base: 2, max_attempts: 8)
    expect(schedule.next_delay(8)).to be_nil
  end

  it "reads RETRY_BASE_SECONDS and MAX_ATTEMPTS by default" do
    schedule = described_class.new(jitter: -> { 0.0 })
    expect(schedule.next_delay(1)).to eq(MockPms::Settings.retry_base_seconds)
    expect(schedule.next_delay(MockPms::Settings.max_attempts)).to be_nil
  end
end
