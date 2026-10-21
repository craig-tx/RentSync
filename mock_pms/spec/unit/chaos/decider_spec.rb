# frozen_string_literal: true

require "spec_helper"
require "benchmark"

RSpec.describe MockPms::Chaos::Decider do
  def settings(**overrides)
    MockPms::Chaos::Settings::DEFAULTS.merge(overrides)
  end

  it "derives uniform values from HMAC-SHA256(seed, stream:counter:field)" do
    expected = OpenSSL::HMAC.digest("SHA256", "1", "delivery:7:duplicate").byteslice(0, 8).unpack1("Q>") / (2.0**64)
    expect(described_class.uniform(seed: 1, stream: "delivery", counter: 7, field: "duplicate")).to eq(expected)
    expect(described_class.uniform(seed: 1, stream: "delivery", counter: 7, field: "duplicate")).to be_between(0, 1)
  end

  it "increments the per-stream counter atomically and gap-free across threads", :committed do
    values = Queue.new
    Array.new(8) { Thread.new { 25.times { values << described_class.draw!(:delivery) } } }.each(&:join)
    all = Array.new(values.size) { values.pop }.sort
    expect(all).to eq((1..200).to_a)
  end

  it "never blocks an api draw behind an open delivery transaction", :committed do
    started = Queue.new
    release = Queue.new
    holder = Thread.new do
      MockPms.db.transaction do
        described_class.draw!(:delivery)
        started << true
        release.pop
      end
    end
    started.pop
    elapsed = Benchmark.realtime { described_class.draw!(:api) }
    release << true
    holder.join
    expect(elapsed).to be < 0.5
  end

  it "resets both counters when settings are updated", :committed do
    described_class.draw!(:delivery)
    described_class.draw!(:api)
    MockPms::Chaos::Settings.update!(duplicate_rate: 0.1)
    expect(MockPms.db[:chaos_counters].select_map(:value)).to eq([0, 0])
  end

  it "decides nothing when every rate is zero" do
    1000.times do |counter|
      expect(described_class.decide(settings, counter: counter)).to eq({})
    end
  end

  it "hits each configured rate within ±1 point over 10,000 decisions" do
    s = settings(duplicate_rate: 0.1, out_of_order_rate: 0.1, delay_rate: 0.1, malformed_rate: 0.1,
                 delay_min_s: 2, delay_max_s: 8)
    decisions = (1..10_000).map { |c| described_class.decide(s, counter: c) }
    rate = ->(key) { decisions.count { |d| d.key?(key) } / 10_000.0 }
    %w[duplicate reorder_hold_s delayed_s malform].each { |key| expect(rate.call(key)).to be_within(0.01).of(0.1) }
    expect(decisions.filter_map { |d| d["reorder_hold_s"] }.minmax).to eq([2, 10])
    expect(decisions.filter_map { |d| d["delayed_s"] }.minmax).to eq([2, 8])
    expect(decisions.filter_map { |d| d["malform"] }.uniq).to contain_exactly("truncate", "drop_field", "bad_type")
  end

  it "reproduces the same decision sequence from the same seed, even in another process", :committed do
    MockPms::Chaos::Settings.update!(seed: 1, duplicate_rate: 0.3, malformed_rate: 0.3, out_of_order_rate: 0.3)
    run = -> { Array.new(50) { described_class.decide_delivery! } }
    first = run.call
    MockPms::Chaos::Settings.update!(seed: 1)
    reader, writer = IO.pipe
    MockPms.db.disconnect # never share live connections across fork; both sides reconnect lazily
    pid = fork do
      reader.close
      writer.write(JSON.generate(run.call))
      writer.close
      exit!(0)
    end
    writer.close
    child = JSON.parse(reader.read)
    Process.wait(pid)
    expect(child).to eq(JSON.parse(JSON.generate(first)))
  end
end
