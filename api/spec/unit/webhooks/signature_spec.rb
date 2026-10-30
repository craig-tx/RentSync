# frozen_string_literal: true

require "spec_helper"

# T036, contracts/webhook-receiver.md steps 2-4 and research R3: the PMS-Signature check
# against 001's frozen vector, the 300 s window, and a constant-time comparison.
RSpec.describe Rentsync::Webhooks::Signature do
  let(:vector) { JSON.parse(File.read(File.join(__dir__, "../../fixtures/signature_vector.json"))) }
  let(:secret) { vector.fetch("secret") }
  let(:t) { vector.fetch("t") }
  let(:body) { vector.fetch("body") }
  let(:header) { "t=#{t},v1=#{vector.fetch('v1')}" }
  let(:now) { Time.at(t).utc }

  def verify(header: self.header, body: self.body, secrets: [secret], now: self.now)
    described_class.verify!(header: header, body: body, secrets: secrets, now: now)
  end

  def failure_reason
    yield
    nil
  rescue described_class::Failure => e
    e.reason
  end

  it "verifies the shared vector and returns which secret signed it" do
    expect(verify).to eq(0)
    expect(verify(secrets: ["whsec_other", secret])).to eq(1)
  end

  it "fails a body with one changed byte as bad_signature" do
    changed = body.sub("evt_TEST", "evt_TESU")
    expect(failure_reason { verify(body: changed) }).to eq("bad_signature")
  end

  it "fails a wrong secret as bad_signature" do
    expect(failure_reason { verify(secrets: ["whsec_wrong"]) }).to eq("bad_signature")
  end

  it "fails when no signing secret is known as bad_signature" do
    expect(failure_reason { verify(secrets: []) }).to eq("bad_signature")
  end

  it "fails a missing header as missing_signature" do
    expect(failure_reason { verify(header: nil) }).to eq("missing_signature")
    expect(failure_reason { verify(header: "") }).to eq("missing_signature")
  end

  it "fails a header it cannot parse as missing_signature" do
    hex = vector.fetch("v1")
    ["v1=#{hex}", "t=#{t}", "t=abc,v1=#{hex}", "t=#{t},v1=#{hex[0, 63]}", "t=#{t},v1=#{hex}zz",
     "t=#{t},v0=#{hex}", "t=#{t};v1=#{hex}"].each do |bad|
      expect(failure_reason { verify(header: bad) }).to eq("missing_signature"), bad
    end
  end

  it "accepts exactly 300 s of skew either way and fails 301 s as stale_timestamp" do
    expect(verify(now: now + 300)).to eq(0)
    expect(verify(now: now - 300)).to eq(0)
    expect(failure_reason { verify(now: now + 301) }).to eq("stale_timestamp")
    expect(failure_reason { verify(now: now - 301) }).to eq("stale_timestamp")
  end

  it "checks the signature before the timestamp" do
    expect(failure_reason { verify(secrets: ["whsec_wrong"], now: now + 3600) }).to eq("bad_signature")
  end

  it "compares in constant time, after a length check" do
    expect(OpenSSL).to receive(:fixed_length_secure_compare).and_call_original
    verify
  end

  it "never puts the secret, the signature or the body in a failure message" do
    message = begin
      verify(body: "#{body} ", secrets: [secret])
    rescue described_class::Failure => e
      e.message
    end
    expect(message).not_to include(secret, vector.fetch("v1"), body)
  end
end
