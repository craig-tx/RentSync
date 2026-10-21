# frozen_string_literal: true

require "spec_helper"

RSpec.describe "/v1 data API", type: :request do
  def app = MockPms::App.build

  let(:op_a) { Factory.operator }
  let(:op_b) { Factory.operator }
  let(:client) { Factory.client.first }
  let(:token) { Factory.tokens(client, op_a).last[:access_token] }

  let!(:lease_a) { Factory.lease(op_a) }
  let!(:lease_b) { Factory.lease(op_b) }
  let!(:charge_a) { Factory.charge(lease_a) }
  let!(:payment_a) do
    Factory.payment(lease_a).tap do |p|
      MockPms::PaymentApplication.create(payment_seq: p.seq, charge_seq: charge_a.seq, amount_cents: 150_000)
    end
  end

  def get_json(path, bearer: token, **params)
    get path, params, { "HTTP_AUTHORIZATION" => "Bearer #{bearer}" }
    JSON.parse(last_response.body)
  end

  describe "auth" do
    it "distinguishes expired from invalid tokens in WWW-Authenticate" do
      expired = token
      MockPms.db[:access_tokens].update(expires_at: Time.now.utc - 1)
      get_json("/v1/properties", bearer: expired)
      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"])
        .to eq('Bearer error="invalid_token", error_description="token expired"')
      get_json("/v1/properties", bearer: "unknown")
      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"])
        .to eq('Bearer error="invalid_token", error_description="token invalid"')
    end

    it "treats a revoked grant's token as invalid" do
      bearer = token
      MockPms::OAuth::Service.revoke!(MockPms::Grant.active.first)
      get_json("/v1/properties", bearer: bearer)
      expect(last_response.headers["WWW-Authenticate"]).to include("token invalid")
    end
  end

  describe "operator scoping" do
    %w[properties tenants leases charges payments].each do |resource|
      it "returns only the token operator's #{resource}" do
        body = get_json("/v1/#{resource}")
        expect(last_response.status).to eq(200)
        expect(body.keys).to contain_exactly("data", "next_cursor")
        expect(body["data"]).not_to be_empty
        ids = body["data"].map { |r| r["id"] }
        other = MockPms.const_get(resource.sub(/s\z/, "").sub("propertie", "property").capitalize)
                       .where(operator_seq: op_b.seq).select_map(:id)
        expect(ids & other).to be_empty
      end
    end

    it "is 404 for another operator's record and 200 for its own" do
      get_json("/v1/leases/#{lease_b.id}")
      expect(last_response.status).to eq(404)
      body = get_json("/v1/leases/#{lease_a.id}")
      expect(last_response.status).to eq(200)
      expect(body["id"]).to eq(lease_a.id)
    end
  end

  describe "filters and validation" do
    it "filters leases by property_id, tenant_id and status" do
      other = Factory.lease(op_a, status: "ended")
      expect(get_json("/v1/leases", property_id: lease_a.property.id)["data"].map { |l| l["id"] }).to eq([lease_a.id])
      expect(get_json("/v1/leases", tenant_id: other.tenant.id)["data"].map { |l| l["id"] }).to eq([other.id])
      expect(get_json("/v1/leases", status: "ended")["data"].map { |l| l["id"] }).to eq([other.id])
    end

    it "filters charges by due_date range and payments by received_at range" do
      Factory.charge(lease_a, period: Date.new(2026, 3, 1))
      expect(get_json("/v1/charges", from: "2026-03-01")["data"].size).to eq(1)
      expect(get_json("/v1/charges", to: "2026-02-28")["data"].size).to eq(1)
      expect(get_json("/v1/payments", from: "2026-02-02T00:00:00Z")["data"]).to be_empty
      expect(get_json("/v1/payments", lease_id: lease_a.id)["data"].size).to eq(1)
    end

    it "rejects limit above 200 with 422 invalid_parameter" do
      body = get_json("/v1/properties", limit: 201)
      expect(last_response.status).to eq(422)
      expect(body.dig("error", "code")).to eq("invalid_parameter")
    end
  end

  describe "shapes" do
    it "renders leases with Money fields and public ids" do
      lease = get_json("/v1/leases/#{lease_a.id}")
      expect(lease).to include("property_id" => lease_a.property.id, "tenant_id" => lease_a.tenant.id,
                               "monthly_rent" => { "amount_cents" => 150_000, "currency" => "USD" },
                               "due_day" => 1, "status" => "active")
      expect(lease.keys).not_to include("seq", "operator_seq")
    end

    it "renders payments with applied_to and, when reversed, a reversal object" do
      MockPms::Reversal.create(payment_seq: payment_a.seq, reason: "nsf", reversed_at: Time.utc(2026, 2, 5),
                               amount_cents: 150_000)
      payment_a.update(status: "reversed")
      payment = get_json("/v1/payments/#{payment_a.id}")
      expect(payment).to include("amount_cents" => 150_000, "currency" => "USD", "status" => "reversed",
                                 "applied_to" => [{ "charge_id" => charge_a.id, "amount_cents" => 150_000 }])
      expect(payment["reversal"]).to include("reason" => "nsf", "amount_cents" => 150_000)
      expect(payment["reversal"]["id"]).to start_with("rev_")
    end
  end
end
