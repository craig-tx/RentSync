# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Delivery::Malformer do
  let(:body) do
    JSON.generate(id: "evt_1", type: "payment.created", occurred_at: "2026-10-01T12:00:00Z", operator_id: "op_1",
                  api_version: "2026-10-01", data: { object: { id: "pay_1" } })
  end

  it "truncate cuts the body in half so it no longer parses" do
    out = described_class.apply("truncate", body)
    expect(out.bytesize).to eq(body.bytesize / 2)
    expect { JSON.parse(out) }.to raise_error(JSON::ParserError)
  end

  it "drop_field removes data" do
    expect(JSON.parse(described_class.apply("drop_field", body)).keys).not_to include("data")
  end

  it "bad_type makes occurred_at a number" do
    expect(JSON.parse(described_class.apply("bad_type", body))["occurred_at"]).to be_a(Integer)
  end

  it "is signed over the bytes actually sent" do
    out = described_class.apply("truncate", body)
    header = MockPms::Delivery::Signer.header(secret: "s", t: 1, body: out)
    expect(MockPms::Delivery::Signer.verify(header: header, secret: "s", body: out)).to be(true)
  end
end
