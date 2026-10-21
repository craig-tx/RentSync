# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Admin::Idempotency do
  let(:runs) { [] }

  def call(key:, body: "{}", &block)
    block ||= lambda {
      runs << 1
      [200, { "n" => runs.size }]
    }
    described_class.call(key: key, method: "POST", path: "/admin/x", body: body, &block)
  end

  it "replays the stored response for the same key and body without rerunning the handler" do
    first = call(key: "k1")
    second = call(key: "k1")
    expect(first).to eq([200, { "n" => 1 }])
    expect(second).to eq([200, { "n" => 1 }])
    expect(runs.size).to eq(1)
  end

  it "rejects the same key with a different body" do
    call(key: "k2", body: '{"a":1}')
    status, body = call(key: "k2", body: '{"a":2}')
    expect(status).to eq(422)
    expect(body.dig("error", "code")).to eq("idempotency_key_mismatch")
  end

  it "always runs the handler when no key is given" do
    call(key: nil)
    call(key: nil)
    expect(runs.size).to eq(2)
  end

  it "releases the key when the handler raises" do
    expect { call(key: "k3") { raise "boom" } }.to raise_error(RuntimeError, "boom")
    expect(call(key: "k3")).to eq([200, { "n" => 1 }])
  end

  it "answers 409 for a duplicate while the first request is in flight", :committed do
    started = Queue.new
    release = Queue.new
    first = Thread.new do
      described_class.call(key: "k4", method: "POST", path: "/admin/x", body: "{}") do
        started << true
        release.pop
        [200, { "ok" => true }]
      end
    end
    started.pop
    status, body = described_class.call(key: "k4", method: "POST", path: "/admin/x", body: "{}") { [200, {}] }
    expect(status).to eq(409)
    expect(body.dig("error", "code")).to eq("idempotency_in_progress")
    release << true
    expect(first.value).to eq([200, { "ok" => true }])
    expect(described_class.call(key: "k4", method: "POST", path: "/admin/x", body: "{}") { [500, {}] })
      .to eq([200, { "ok" => true }])
  end
end
