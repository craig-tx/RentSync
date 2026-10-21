# frozen_string_literal: true

require "spec_helper"

RSpec.describe "admin clients and grants", type: :request do
  def app = MockPms::App.build

  def admin_headers(extra = {})
    { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}", "CONTENT_TYPE" => "application/json" }.merge(extra)
  end

  def register(body = { name: "local", redirect_uris: ["http://localhost:9999/cb"] }, headers = {})
    post "/admin/clients", JSON.generate(body), admin_headers(headers)
    JSON.parse(last_response.body)
  end

  it "registers a client and shows the secrets once" do
    body = register
    expect(last_response.status).to eq(201)
    expect(body["client_id"]).to start_with("client_")
    expect(body["signing_secret"]).to start_with("whsec_")
    client = MockPms::Client.first(id: body["client_id"])
    expect(client.secret_digest).to eq(Digest::SHA256.hexdigest(body["client_secret"]))
    expect(client.values.values.map(&:to_s)).not_to include(body["client_secret"])
  end

  it "never stores secrets in the idempotency table and ignores Idempotency-Key on registration" do
    first = register({ name: "a", redirect_uris: ["http://x.test/cb"] }, "HTTP_IDEMPOTENCY_KEY" => "same")
    second = register({ name: "a", redirect_uris: ["http://x.test/cb"] }, "HTTP_IDEMPOTENCY_KEY" => "same")
    expect(second["client_id"]).not_to eq(first["client_id"])
    stored = MockPms.db[:admin_idempotency_keys].all.to_s
    expect(stored).not_to include(first["client_secret"], first["signing_secret"])
  end

  it "requires at least one redirect_uri" do
    register({ name: "x", redirect_uris: [] })
    expect(last_response.status).to eq(422)
  end

  it "lists clients without secrets" do
    register
    get "/admin/clients", {}, admin_headers
    listed = JSON.parse(last_response.body)
    expect(listed.first.keys).not_to include("client_secret", "secret_digest", "signing_secret")
  end

  it "updates subscriber_url, redirect_uris and rate_limit_per_minute" do
    id = register["client_id"]
    patch "/admin/clients/#{id}", JSON.generate(subscriber_url: "http://receiver:9999/webhooks",
                                                rate_limit_per_minute: 10,
                                                redirect_uris: ["http://localhost:1/cb"]), admin_headers
    expect(last_response.status).to eq(200)
    client = MockPms::Client.first(id: id)
    expect([client.subscriber_url, client.rate_limit_per_minute, client.redirect_uris.to_a])
      .to eq(["http://receiver:9999/webhooks", 10, ["http://localhost:1/cb"]])
  end

  it "revokes a grant idempotently and lists grants" do
    client = Factory.client.first
    operator = Factory.operator
    grant, = Factory.tokens(client, operator)
    post "/admin/grants/#{grant.id}/revoke", "{}", admin_headers
    expect(last_response.status).to eq(200)
    revoked_at = JSON.parse(last_response.body)["revoked_at"]
    post "/admin/grants/#{grant.id}/revoke", "{}", admin_headers
    expect(JSON.parse(last_response.body)["revoked_at"]).to eq(revoked_at)
    get "/admin/grants", {}, admin_headers
    expect(JSON.parse(last_response.body).first.keys).to include("client_id", "operator_id", "created_at", "revoked_at")
  end
end
