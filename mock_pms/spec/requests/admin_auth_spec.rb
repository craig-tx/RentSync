# frozen_string_literal: true

require "spec_helper"

RSpec.describe "admin authentication", type: :request do
  def app = MockPms::App.build

  it "rejects a missing token with 401 and the error envelope" do
    get "/admin/status"
    expect(last_response.status).to eq(401)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unauthorized")
  end

  it "rejects a wrong token with 401 using a constant-time comparison" do
    expect(Rack::Utils).to receive(:secure_compare).at_least(:once).and_call_original
    get "/admin/status", {}, { "HTTP_AUTHORIZATION" => "Bearer wrong" }
    expect(last_response.status).to eq(401)
  end

  it "accepts the admin token" do
    get "/admin/status", {}, { "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_TOKEN')}" }
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to include("status" => "ok")
  end
end
