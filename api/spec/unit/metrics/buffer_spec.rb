# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rentsync::Metrics::Buffer do
  subject(:buffer) { described_class.new(cap: 5) }

  it "accumulates counter increments per canonical label set" do
    buffer.increment("c_total", { b: "2", a: "1" })
    buffer.increment("c_total", { a: "1", b: "2" }, 2)
    deltas = buffer.swap!
    expect(deltas[:counters]).to eq("c_total" => { "a=1|b=2" => 3 })
  end

  it "records histogram buckets, sum and count" do
    buffer.observe("h_seconds", { route: "/x" }, 0.02)
    buffer.observe("h_seconds", { route: "/x" }, 3.0)
    hist = buffer.swap![:histograms]["h_seconds"]["route=/x"]
    expect(Rentsync::Metrics::BUCKETS).to eq([0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10])
    expect(hist[:buckets][Rentsync::Metrics::BUCKETS.index(0.025)]).to eq(1)
    expect(hist[:buckets][Rentsync::Metrics::BUCKETS.index(5)]).to eq(1)
    expect(hist[:sum]).to be_within(1e-9).of(3.02)
    expect(hist[:count]).to eq(2)
  end

  it "swap! returns the deltas and leaves the buffer empty" do
    buffer.increment("c_total", {})
    expect(buffer.swap![:counters]).not_to be_empty
    expect(buffer.swap!).to eq(counters: {}, histograms: {})
  end

  it "drops new label sets beyond the field cap and counts the drops" do
    6.times { |i| buffer.increment("c_total", { i: i.to_s }) }
    deltas = buffer.swap!
    expect(deltas[:counters]["c_total"].size).to eq(5)
    expect(deltas[:counters]["rentsync_metrics_dropped_total"]).to eq("" => 1)
  end

  it "merges deltas back after a failed flush" do
    buffer.increment("c_total", {}, 2)
    deltas = buffer.swap!
    buffer.increment("c_total", {}, 1)
    buffer.merge!(deltas)
    expect(buffer.swap![:counters]["c_total"][""]).to eq(3)
  end
end
