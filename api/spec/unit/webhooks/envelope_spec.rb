# frozen_string_literal: true

require "spec_helper"

# T037, contracts/webhook-receiver.md step 5 and 001's webhooks.md "Envelope": the mock's chaos
# malformations, unknown types and a mismatched event ID are malformed_body; the four real types
# pass, with the business keys of research R4.
RSpec.describe Rentsync::Webhooks::Envelope do
  let(:objects) do
    {
      "payment.created" => { "id" => "pay_1", "status" => "settled", "amount_cents" => 125_000 },
      "payment.reversed" => { "id" => "pay_1", "status" => "reversed",
                              "reversal" => { "reason" => "nsf", "reversed_at" => "2026-10-31T15:00:00Z" } },
      "lease.updated" => { "id" => "lea_1", "status" => "active" },
      "tenant.moved_out" => { "tenant" => { "id" => "ten_1" }, "lease" => { "id" => "lea_1" },
                              "move_out_date" => "2026-11-15" }
    }
  end

  def envelope(type = "payment.created", **overrides)
    { "id" => "evt_1", "type" => type, "occurred_at" => "2026-10-31T14:05:12Z", "operator_id" => "op_1",
      "api_version" => "2026-10-01", "data" => { "object" => objects.fetch(type, {}) } }
      .merge(overrides.transform_keys(&:to_s))
  end

  def body(type = "payment.created", **overrides) = JSON.generate(envelope(type, **overrides))

  def parse(raw, event_id: "evt_1") = described_class.parse(raw, event_id: event_id)

  def reason_for(raw, event_id: "evt_1")
    parse(raw, event_id: event_id)
    nil
  rescue described_class::Invalid => e
    e.reason
  end

  describe "the four event types" do
    it "parses each, keeping the parsed payload and the occurrence time" do
      objects.each_key do |type|
        parsed = parse(body(type))
        expect(parsed).to have_attributes(id: "evt_1", type: type, operator_id: "op_1",
                                          occurred_at: Time.utc(2026, 10, 31, 14, 5, 12))
        expect(parsed.payload).to eq(envelope(type))
      end
    end

    it "gives payments a business key and lease events none (research R4)" do
      expect(parse(body("payment.created")).business_key).to eq("payment.created:pay_1")
      expect(parse(body("payment.reversed")).business_key).to eq("payment.reversed:pay_1")
      expect(parse(body("lease.updated")).business_key).to be_nil
      expect(parse(body("tenant.moved_out")).business_key).to be_nil
    end
  end

  # The same transformations as mock_pms/lib/mock_pms/delivery/malformer.rb, which this service
  # cannot load: the mock signs these bodies validly, so parsing is what must reject them.
  describe "the mock's chaos malformations" do
    let(:good) { body }

    it "rejects truncate" do
      expect(reason_for(good.byteslice(0, good.bytesize / 2))).to eq("malformed_body")
    end

    it "rejects drop_field" do
      expect(reason_for(JSON.generate(JSON.parse(good).except("data")))).to eq("malformed_body")
    end

    it "rejects bad_type" do
      parsed = JSON.parse(good)
      parsed["occurred_at"] = Time.iso8601(parsed["occurred_at"]).to_i
      expect(reason_for(JSON.generate(parsed))).to eq("malformed_body")
    end
  end

  describe "other bad bodies" do
    it "rejects an unknown type" do
      expect(reason_for(body(type: "payment.refunded"))).to eq("malformed_body")
    end

    it "rejects an id different from PMS-Event-Id" do
      expect(reason_for(body, event_id: "evt_2")).to eq("malformed_body")
      expect(reason_for(body, event_id: nil)).to eq("malformed_body")
    end

    it "rejects a missing or blank required field" do
      %w[id type occurred_at operator_id].each do |field|
        expect(reason_for(JSON.generate(envelope.except(field)))).to eq("malformed_body"), field
        expect(reason_for(body(field => ""))).to eq("malformed_body"), field
      end
    end

    it "rejects an occurred_at that is not ISO 8601" do
      expect(reason_for(body(occurred_at: "31/10/2026"))).to eq("malformed_body")
    end

    it "rejects a data.object that is not an object" do
      expect(reason_for(body(data: { "object" => [] }))).to eq("malformed_body")
      expect(reason_for(body(data: "x"))).to eq("malformed_body")
    end

    it "rejects a payment without an object id, which its business key needs" do
      expect(reason_for(body(data: { "object" => { "status" => "settled" } }))).to eq("malformed_body")
    end

    it "rejects JSON that is not an object, and bytes that are not UTF-8" do
      expect(reason_for("[1,2]")).to eq("malformed_body")
      expect(reason_for("")).to eq("malformed_body")
      expect(reason_for(body.b.sub("op_1", "op_\xC3".b))).to eq("malformed_body")
    end

    it "never echoes body content in the failure message" do
      message = begin
        parse(body(type: "secret-tenant-name"))
      rescue described_class::Invalid => e
        e.message
      end
      expect(message).not_to include("secret-tenant-name")
    end
  end
end
