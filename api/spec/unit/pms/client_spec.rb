# frozen_string_literal: true

require "spec_helper"

# T047, research R6: every PMS API call takes a token from a Redis bucket shared by all
# instances, honours a shared Retry-After block, backs off with full jitter, fails closed
# without Redis, and renews an expiring access token first.
RSpec.describe Rentsync::Pms::Client do
  before(:context) { @pms = FakePms.new.start }
  after(:context) { @pms.stop }

  let(:pms) { @pms.script([200, {}, { data: [{ id: "pay_1" }], next_cursor: nil }]) }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end
  let(:connection) do
    operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
                                   pms_operator_name: "Lone Star Rentals", status: "active",
                                   access_expires_at: Time.now.utc + 3600)
  end
  let(:renewal) { double("renewal", access_token!: "AT-1") }
  let(:sleeps) { [] }
  let(:now) { Time.utc(2026, 10, 31, 14) }

  before do
    pms.requests.clear
    freeze_time(now)
  end

  # Sleeping advances the frozen clock, so shared blocks expire as they would in real time.
  def client(on_sleep: nil, random: -> { 1.0 })
    described_class.new(connection, base_url: pms.base_url, renewal: renewal, random: random, read_timeout: 0.5,
                                    sleeper: lambda { |s|
                                      sleeps << s
                                      advance(s)
                                      on_sleep&.call
                                    })
  end

  def bucket = Rentsync::Redis.client.hgetall(Rentsync::Redis.key("rl", "pms", "client_A"))

  it "gets a path with the access token and returns the parsed body" do
    body = client.get("/v1/payments", limit: 200)
    expect(body).to eq("data" => [{ "id" => "pay_1" }], "next_cursor" => nil)
    expect(pms.requests.last).to have_attributes(path: "/v1/payments", query: { "limit" => "200" },
                                                 authorization: "Bearer AT-1")
  end

  it "takes a token from the bucket keyed on the PMS client for every call" do
    client.get("/v1/payments")
    first = bucket.fetch("tokens").to_f
    client.get("/v1/payments")
    expect(bucket.fetch("tokens").to_f).to be < first
    expect(first).to be < Rentsync::Settings.pms_rate_limit_per_minute
  end

  it "waits for a token when the bucket is empty, and counts the wait" do
    key = Rentsync::Redis.key("rl", "pms", "client_A")
    seconds, micros = Rentsync::Redis.client.time
    Rentsync::Redis.client.hset(key, "tokens", "0", "ts_ms", ((seconds * 1000) + (micros / 1000)).to_s)
    c = client(on_sleep: -> { Rentsync::Redis.client.del(key) })
    c.get("/v1/payments")
    expect(sleeps.size).to eq(1)
    expect(sleeps.first).to be_within(0.2).of(60.0 / Rentsync::Settings.pms_rate_limit_per_minute)
    expect(c.rate_limit_waits).to eq(1)
    expect(c.rate_limit_wait_s).to be_positive
  end

  it "on 429 stores a shared block from Retry-After, so another instance waits too" do
    pms.script([429, { "Retry-After" => "3" }, { error: { code: "rate_limited" } }],
               [200, {}, { data: [], next_cursor: nil }])
    first = client
    first.get("/v1/payments")
    expect(sleeps.first).to be >= 3
    expect(first.rate_limit_waits).to eq(1)

    # Back to the moment of the 429: a fresh instance finds the block in Redis and waits it out.
    freeze_time(now)
    sleeps.clear
    pms.requests.clear
    client.get("/v1/payments")
    expect(sleeps.first).to be_within(0.01).of(3)
    expect(pms.requests.size).to eq(1)
  end

  it "keeps the later block when a shorter Retry-After arrives" do
    described_class.block!("client_A", seconds: 30)
    described_class.block!("client_A", seconds: 1)
    expect(described_class.blocked_until("client_A")).to eq(now + 30)
    described_class.block!("client_A", seconds: 45)
    expect(described_class.blocked_until("client_A")).to eq(now + 45)
  end

  it "retries 5xx with full jitter, base 1 s, and raises on the 6th failure" do
    pms.script([503, {}, {}])
    expect { client(random: -> { 0.5 }).get("/v1/payments") }
      .to raise_error(described_class::Failed) { |e| expect(e.status).to eq(503) }
    expect(pms.requests.size).to eq(6)
    expect(sleeps).to eq([0.5, 1.0, 2.0, 4.0, 8.0])
  end

  it "caps each backoff at 60 s" do
    pms.script([500, {}, {}])
    expect { client.get("/v1/payments") }.to raise_error(described_class::Failed)
    expect(described_class.backoff_s(8, 1.0)).to eq(60)
    expect(sleeps).to eq([1.0, 2.0, 4.0, 8.0, 16.0])
  end

  it "retries timeouts like 5xx" do
    pms.script(:hang, [200, {}, { data: [], next_cursor: nil }])
    expect(client.get("/v1/payments")).to eq("data" => [], "next_cursor" => nil)
    expect(sleeps).to eq([1.0])
  end

  it "fails closed when Redis is down: it waits and never calls the PMS" do
    allow(Rentsync::Redis).to receive(:evalsha).and_raise(Redis::CannotConnectError)
    allow(Rentsync::Redis.client).to receive(:get).and_raise(Redis::CannotConnectError)
    expect { client.get("/v1/payments") }.to raise_error(described_class::Unavailable)
    expect(pms.requests).to be_empty
    expect(sleeps.size).to eq(5)
  end

  it "asks the renewal for the token on every call, so an expiring one is renewed first" do
    allow(renewal).to receive(:access_token!).and_return("AT-OLD", "AT-NEW")
    client.get("/v1/payments")
    client.get("/v1/payments")
    expect(pms.requests.map(&:authorization)).to eq(["Bearer AT-OLD", "Bearer AT-NEW"])
  end

  it "on a 401 forces one renewal and retries; a second 401 raises" do
    allow(renewal).to receive(:access_token!).and_return("AT-REVOKED", "AT-RENEWED")
    pms.script([401, {}, {}], [200, {}, { data: [], next_cursor: nil }])
    client.get("/v1/payments")
    expect(pms.requests.map(&:authorization)).to eq(["Bearer AT-REVOKED", "Bearer AT-RENEWED"])
    expect(connection.refresh.access_expires_at).to be <= now

    pms.script([401, {}, {}])
    expect { client.get("/v1/payments") }.to raise_error(described_class::Unauthorized)
  end

  it "lets a refusal to renew through, so the run can record needs_reauth" do
    allow(renewal).to receive(:access_token!).and_raise(Rentsync::Pms::Renewal::NeedsReauth)
    expect { client.get("/v1/payments") }.to raise_error(Rentsync::Pms::Renewal::NeedsReauth)
    expect(pms.requests).to be_empty
  end
end
