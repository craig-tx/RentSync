# frozen_string_literal: true

require "spec_helper"

RSpec.describe "OAuth endpoints", type: :request do
  def app = MockPms::App.build

  let(:operator) { Factory.operator(login: "lonestar") }
  let!(:registered) { Factory.client }
  let(:client) { registered[0] }
  let(:secret) { registered[1] }
  let(:redirect) { "http://localhost:9999/cb" }

  def authorize_params(**extra)
    { response_type: "code", client_id: client.id, redirect_uri: redirect, state: "xyz" }.merge(extra)
  end

  def approve!(decision: "approve", password: "lonestar-pass")
    operator
    post "/oauth/authorize", authorize_params(login: "lonestar", password: password, decision: decision)
  end

  def code_from_redirect = Rack::Utils.parse_query(URI(last_response.location).query)["code"]

  describe "GET /oauth/authorize" do
    it "renders the HTML approval page for a registered client" do
      get "/oauth/authorize", authorize_params
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("text/html")
      expect(last_response.body).to include("<form", client.name)
    end

    it "is 400 without redirecting for an unknown client or unregistered redirect_uri" do
      get "/oauth/authorize", authorize_params(client_id: "client_UNKNOWN")
      expect(last_response.status).to eq(400)
      expect(last_response.location).to be_nil
      get "/oauth/authorize", authorize_params(redirect_uri: "http://evil.test/cb")
      expect(last_response.status).to eq(400)
    end
  end

  describe "POST /oauth/authorize" do
    it "redirects with a code and state on approve" do
      approve!
      expect(last_response.status).to eq(302)
      expect(last_response.location).to start_with("#{redirect}?")
      query = Rack::Utils.parse_query(URI(last_response.location).query)
      expect(query["state"]).to eq("xyz")
      expect(query["code"]).not_to be_empty
    end

    it "redirects with error=access_denied on deny" do
      approve!(decision: "deny")
      expect(last_response.status).to eq(302)
      expect(Rack::Utils.parse_query(URI(last_response.location).query))
        .to eq("error" => "access_denied", "state" => "xyz")
    end

    it "re-renders the form on wrong credentials" do
      approve!(password: "nope")
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Invalid credentials")
    end
  end

  describe "POST /oauth/token" do
    it "exchanges a code using client_secret_basic" do
      approve!
      basic_authorize client.id, secret
      post "/oauth/token", grant_type: "authorization_code", code: code_from_redirect, redirect_uri: redirect
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to include("token_type" => "Bearer", "scope" => "read", "expires_in" => 300)
      expect(body.keys).to include("access_token", "refresh_token")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")
    end

    it "exchanges a code using client_secret_post, then refreshes" do
      approve!
      post "/oauth/token", grant_type: "authorization_code", code: code_from_redirect, redirect_uri: redirect,
                           client_id: client.id, client_secret: secret
      refresh = JSON.parse(last_response.body)["refresh_token"]
      post "/oauth/token", grant_type: "refresh_token", refresh_token: refresh, client_id: client.id,
                           client_secret: secret
      expect(last_response.status).to eq(200)
      post "/oauth/token", grant_type: "refresh_token", refresh_token: refresh, client_id: client.id,
                           client_secret: secret
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to eq("invalid_grant")
    end

    it "is 401 invalid_client for a bad secret" do
      approve!
      basic_authorize client.id, "wrong"
      post "/oauth/token", grant_type: "authorization_code", code: code_from_redirect, redirect_uri: redirect
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("invalid_client")
    end

    it "is 400 unsupported_grant_type for an unknown grant" do
      basic_authorize client.id, secret
      post "/oauth/token", grant_type: "password"
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to eq("unsupported_grant_type")
    end
  end
end
