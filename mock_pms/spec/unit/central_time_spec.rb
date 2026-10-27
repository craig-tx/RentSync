# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::CentralTime do
  def central(*utc) = described_class.format(Time.utc(*utc))

  it "shows US Central daylight time in summer" do
    expect(central(2026, 10, 27, 12, 0, 5)).to eq("2026-10-27 07:00:05 CDT")
  end

  it "shows US Central standard time in winter" do
    expect(central(2026, 1, 15, 18, 0, 0)).to eq("2026-01-15 12:00:00 CST")
  end

  it "changes the date when UTC is already tomorrow" do
    expect(central(2026, 1, 16, 3, 30, 0)).to eq("2026-01-15 21:30:00 CST")
  end

  # Daylight time starts the second Sunday of March at 2:00 local standard time (08:00 UTC).
  it "switches to daylight time at 2:00 on the second Sunday of March" do
    expect(central(2026, 3, 8, 7, 59, 59)).to eq("2026-03-08 01:59:59 CST")
    expect(central(2026, 3, 8, 8, 0, 0)).to eq("2026-03-08 03:00:00 CDT")
  end

  # Daylight time ends the first Sunday of November at 2:00 local daylight time (07:00 UTC).
  it "switches back to standard time at 2:00 on the first Sunday of November" do
    expect(central(2026, 11, 1, 6, 59, 59)).to eq("2026-11-01 01:59:59 CDT")
    expect(central(2026, 11, 1, 7, 0, 0)).to eq("2026-11-01 01:00:00 CST")
  end

  it "finds the switch dates in another year" do
    expect(central(2027, 3, 14, 8, 0, 0)).to eq("2027-03-14 03:00:00 CDT")
    expect(central(2027, 11, 7, 7, 0, 0)).to eq("2027-11-07 01:00:00 CST")
  end
end
