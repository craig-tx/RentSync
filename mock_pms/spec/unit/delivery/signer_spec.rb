# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Delivery::Signer do
  let(:vector) { JSON.parse(File.read(File.expand_path("../../fixtures/signature_vector.json", __dir__))) }

  it "matches the independently computed vector" do
    header = described_class.header(secret: vector["secret"], t: vector["t"], body: vector["body"])
    expect(header).to eq("t=#{vector['t']},v1=#{vector['v1']}")
  end

  it "verifies the vector and rejects a one-byte change" do
    header = "t=#{vector['t']},v1=#{vector['v1']}"
    expect(described_class.verify(header: header, secret: vector["secret"], body: vector["body"])).to be(true)
    tampered = vector["body"].sub("created", "createe")
    expect(described_class.verify(header: header, secret: vector["secret"], body: tampered)).to be(false)
    expect(described_class.verify(header: "garbage", secret: vector["secret"], body: vector["body"])).to be(false)
  end

  it "signs raw bytes, including bodies that are not valid UTF-8" do
    body = "\xFF\xFE{".b
    header = described_class.header(secret: "s", t: 1, body: body)
    expect(described_class.verify(header: header, secret: "s", body: body)).to be(true)
  end
end
