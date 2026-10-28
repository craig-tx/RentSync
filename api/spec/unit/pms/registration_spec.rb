# frozen_string_literal: true

require "spec_helper"

# T020, research R9: one active PMS client per deployment, registered through the mock's admin
# API, under an advisory lock.
RSpec.describe Rentsync::Pms::Registration do
  let(:admin) { FakeAdminApi.new }
  let(:io) { StringIO.new }

  around do |example|
    original = Rentsync::Logging.io
    Rentsync::Logging.io = io
    example.run
  ensure
    Rentsync::Logging.io = original
  end

  def ensure!(api = admin) = described_class.new(admin: api).ensure!

  def active = Rentsync::PmsClient.active.all

  it "registers when there is no client, with the deployment's name and URLs" do
    result = ensure!
    expect(result).to eq(action: :registered, client_id: "client_FAKE1")
    expect(admin.created).to eq([{ name: "rentsync-#{Rentsync::Settings.deployment_id}",
                                   redirect_uris: ["http://app.test/connections/callback"],
                                   subscriber_url: "http://app.test/webhooks/pms" }])
    row = active.first
    expect(row.client_id).to eq("client_FAKE1")
    expect(row.pms_key).to eq("mock_pms")
    expect(row.base_url).to eq("http://pms.test")
    expect(row.client_secret_plaintext).to eq("CS-SECRET-1")
    expect(row.signing_secret_plaintext).to eq("SS-SECRET-1")
  end

  it "keeps a client the PMS still has" do
    ensure!
    expect(ensure!).to eq(action: :kept, client_id: "client_FAKE1")
    expect(admin.created.size).to eq(1)
    expect(Rentsync::PmsClient.count).to eq(1)
  end

  context "when the PMS lost the client (a mock reset)" do
    def operator(email = "ann@example.test")
      Rentsync::Operator.create(email: email, name: "Operator", password_digest: "x")
    end

    def connection(client, status, pms_operator_id, owner: operator)
      Rentsync::PmsConnection.create(operator_id: owner.id, pms_client_id: client.id, status: status,
                                     pms_operator_id: pms_operator_id, pms_operator_name: "Lone Star")
    end

    it "supersedes it, registers again, and sends live connections to reauthorization" do
      ensure!
      old = active.first
      live = connection(old, "active", "op_1")
      failing = connection(old, "renewal_failing", "op_2", owner: operator("bo@example.test"))
      admin.forget!("client_FAKE1")

      expect(ensure!).to eq(action: :replaced, client_id: "client_FAKE2")
      expect(active.map(&:client_id)).to eq(["client_FAKE2"])
      expect(Rentsync::PmsClient[old.id].superseded_at).not_to be_nil
      expect([live.refresh.status, failing.refresh.status]).to eq(%w[needs_reauth needs_reauth])
    end

    it "leaves a disconnected connection disconnected" do
      ensure!
      gone = connection(active.first, "disconnected", "op_1")
      admin.forget!("client_FAKE1")
      ensure!
      expect(gone.refresh.status).to eq("disconnected")
    end
  end

  it "never logs or returns a secret" do
    result = ensure!
    admin.forget!("client_FAKE1")
    ensure!
    text = io.string + result.to_s
    expect(text).not_to include("CS-SECRET", "SS-SECRET")
    expect(io.string).to include("client_FAKE1")
  end

  it "stores nothing when the PMS refuses the registration" do
    failing = FakeAdminApi.new
    def failing.create_client(**) = raise(Rentsync::Pms::AdminApi::Error, "POST /admin/clients: HTTP 401")
    expect { ensure!(failing) }.to raise_error(Rentsync::Pms::AdminApi::Error)
    expect(Rentsync::PmsClient.count).to eq(0)
  end

  describe "#install! (credentials handed over out of band)" do
    it "replaces the active client without calling the admin API" do
      ensure!
      offline = FakeAdminApi.new
      result = described_class.new(admin: offline).install!(client_id: "client_REAL", client_secret: "CS-REAL",
                                                            signing_secret: "SS-REAL")
      expect(result).to eq(action: :replaced, client_id: "client_REAL")
      expect(offline.created).to be_empty
      expect(active.map(&:client_id)).to eq(["client_REAL"])
      expect(active.first.signing_secret_plaintext).to eq("SS-REAL")
    end
  end

  context "with two concurrent runs", :committed do
    it "makes exactly one POST and leaves exactly one active client" do
      slow = FakeAdminApi.new(delay: 0.3)
      results = Array.new(2) { Thread.new { described_class.new(admin: slow).ensure! } }.map(&:value)
      expect(slow.created.size).to eq(1)
      expect(results.map { |r| r[:action] }).to contain_exactly(:registered, :kept)
      expect(Rentsync::PmsClient.active.count).to eq(1)
    end
  end
end
