# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rentsync::Metrics::Flusher do
  let(:redis) { Rentsync::Redis.client }

  def key(family) = Rentsync::Redis.key("metrics", family)

  it "sums exactly across concurrent flushes from several threads (no lock)" do
    threads = Array.new(4) do
      Thread.new do
        buffer = Rentsync::Metrics::Buffer.new
        flusher = described_class.new(buffer: buffer)
        1000.times do |n|
          buffer.increment("t_total", { k: "v" })
          flusher.flush! if (n % 97).zero?
        end
        flusher.flush!
      end
    end
    threads.each(&:join)
    expect(redis.hget(key("t_total"), "k=v").to_i).to eq(4000)
  end

  it "writes counters with HINCRBY and sums with HINCRBYFLOAT inside one MULTI" do
    buffer = Rentsync::Metrics::Buffer.new
    buffer.increment("t_total", {})
    buffer.observe("h_seconds", {}, 0.5)
    calls = []
    tx = double("tx")
    allow(tx).to receive(:hincrby) { |*args| calls << [:hincrby, *args] }
    allow(tx).to receive(:hincrbyfloat) { |*args| calls << [:hincrbyfloat, *args] }
    client = double("redis")
    expect(client).to receive(:multi).once.and_yield(tx)
    described_class.new(buffer: buffer, client: client).flush!
    expect(calls.map(&:first).uniq).to contain_exactly(:hincrby, :hincrbyfloat)
    expect(calls).to include([:hincrby, key("t_total"), "", 1])
    expect(calls).to include([:hincrbyfloat, key("h_seconds_sum"), "", 0.5])
  end

  it "merges deltas back when Redis fails, and sends them on the next flush" do
    buffer = Rentsync::Metrics::Buffer.new
    buffer.increment("t_total", {}, 5)
    broken = double("redis")
    allow(broken).to receive(:multi).and_raise(Redis::CannotConnectError)
    described_class.new(buffer: buffer, client: broken).flush!
    described_class.new(buffer: buffer).flush!
    expect(redis.hget(key("t_total"), "").to_i).to eq(5)
  end
end
