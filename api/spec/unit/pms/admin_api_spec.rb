# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rentsync::Pms::AdminApi do
  let(:sent) { [] }

  def api(status, body)
    described_class.new(base_url: "http://pms-api.test", token: "ADMIN-TOK",
                        request: lambda { |req, uri|
                          sent << { method: req.method, url: uri.to_s, auth: req["Authorization"], body: req.body }
                          [status, body]
                        })
  end

  it "lists client IDs with the admin bearer token" do
    ids = api(200, JSON.generate([{ "client_id" => "client_A" }, { "client_id" => "client_B" }])).client_ids
    expect(ids).to eq(%w[client_A client_B])
    expect(sent.last).to include(method: "GET", url: "http://pms-api.test/admin/clients", auth: "Bearer ADMIN-TOK")
  end

  it "registers a client with a JSON body" do
    response = api(201, JSON.generate("client_id" => "client_A", "client_secret" => "cs", "signing_secret" => "ss"))
               .create_client(name: "rentsync-x", redirect_uris: ["http://app.test/cb"], subscriber_url: "http://h/w")
    expect(response["client_id"]).to eq("client_A")
    expect(JSON.parse(sent.last[:body])).to eq("name" => "rentsync-x", "redirect_uris" => ["http://app.test/cb"],
                                               "subscriber_url" => "http://h/w")
  end

  it "reports a refusal by status only, never the body or token" do
    expect { api(401, '{"secret":"LEAKY"}').client_ids }.to raise_error(described_class::Error) { |e|
      expect(e.message).to eq("GET /admin/clients: HTTP 401")
    }
  end

  it "refuses a response that is not JSON, or not a list" do
    expect { api(200, "<html>").client_ids }.to raise_error(described_class::Error, /not JSON/)
    expect { api(200, "{}").client_ids }.to raise_error(described_class::Error, /expected a list/)
  end

  it "turns a network failure into an error naming only its class" do
    failing = described_class.new(base_url: "http://pms-api.test", token: "t",
                                  request: ->(*) { raise Errno::ECONNREFUSED })
    expect { failing.client_ids }.to raise_error(described_class::Error, "GET /admin/clients: Errno::ECONNREFUSED")
  end
end
