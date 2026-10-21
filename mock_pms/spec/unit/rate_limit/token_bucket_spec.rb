# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::RateLimit::Limiter do
  let(:now) { 1_800_000_000_000 }

  def check(client = "client_A", capacity: 60, at: now)
    described_class.check(client_id: client, capacity: capacity, now_ms: at)
  end

  it "allows capacity requests at one instant, then denies with the exact wait" do
    results = Array.new(60) { check }
    expect(results.map { |r| r[:allowed] }.uniq).to eq([true])
    denied = check
    expect(denied).to include(allowed: false, retry_after_ms: 1000, remaining: 0)
  end

  it "refills continuously: one token per second at 60/min" do
    60.times { check }
    expect(check(at: now + 999)[:allowed]).to be(false)
    expect(check(at: now + 1000)[:allowed]).to be(true)
    expect(check(at: now + 1000)[:allowed]).to be(false)
  end

  it "keeps clients independent" do
    60.times { check("client_A") }
    expect(check("client_A")[:allowed]).to be(false)
    expect(check("client_B")[:allowed]).to be(true)
  end

  it "is atomic under concurrent calls" do
    results = Queue.new
    Array.new(10) { Thread.new { 10.times { results << check } } }.each(&:join)
    allowed = Array.new(results.size) { results.pop }.count { |r| r[:allowed] }
    expect(allowed).to eq(60)
  end

  it "expires idle buckets after at most a full refill plus 1 s" do
    check
    ttl = MockPms::Redis.client.pttl(MockPms::Redis.key("rl", "client_A"))
    expect(ttl).to be_between(1, 60_000 + 1000)
  end

  it "honors a per-client capacity" do
    3.times { expect(check(capacity: 3)[:allowed]).to be(true) }
    expect(check(capacity: 3)).to include(allowed: false, retry_after_ms: 20_000)
  end

  it "uses Redis TIME when no clock is passed" do
    result = described_class.check(client_id: "client_T", capacity: 60)
    expect(result[:allowed]).to be(true)
  end
end
