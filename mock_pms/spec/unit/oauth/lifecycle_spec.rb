# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::OAuth::Service do
  let(:operator) { Factory.operator }
  let(:client) { Factory.client.first }
  let(:redirect) { "http://localhost:9999/cb" }
  let(:t0) { Time.utc(2026, 10, 20, 12) }

  before { freeze_time(t0) }

  def approve(**opts) = described_class.approve!(client: client, operator: operator, redirect_uri: redirect, **opts)

  def exchange(code, **opts)
    described_class.exchange_code!(client: client, code: code, redirect_uri: redirect, **opts)
  end

  def expect_invalid_grant(&)
    expect(&).to raise_error(MockPms::OAuth::Error) { |e| expect(e.code).to eq("invalid_grant") }
  end

  it "issues a single-use code that expires 60 s after issue" do
    code = approve
    stored = MockPms.db[:authorization_codes].first
    expect(stored[:expires_at]).to eq(t0 + 60)
    expect(stored[:code_digest]).to eq(described_class.digest(code))
    expect(exchange(code)).to include(token_type: "Bearer", scope: "read", expires_in: 300)
    expect_invalid_grant { exchange(code) }
  end

  it "rejects an expired code" do
    code = approve
    advance(61)
    expect_invalid_grant { exchange(code) }
  end

  it "rejects a redirect_uri mismatch" do
    code = approve
    expect_invalid_grant do
      described_class.exchange_code!(client: client, code: code, redirect_uri: "http://evil.test/cb")
    end
  end

  it "enforces PKCE S256" do
    verifier = "v" * 50
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    code = approve(code_challenge: challenge, code_challenge_method: "S256")
    expect_invalid_grant { exchange(code, code_verifier: "wrong" * 10) }
    code = approve(code_challenge: challenge, code_challenge_method: "S256")
    expect(exchange(code, code_verifier: verifier)).to include(:access_token)
  end

  it "sets access tokens to issue + 300 s and refresh tokens to issue + 30 days" do
    exchange(approve)
    expect(MockPms.db[:access_tokens].get(:expires_at)).to eq(t0 + 300)
    expect(MockPms.db[:refresh_tokens].get(:expires_at)).to eq(t0 + (30 * 86_400))
  end

  it "rotates refresh tokens and rejects reuse of the old one" do
    first = exchange(approve)
    second = described_class.refresh!(client: client, refresh_token: first[:refresh_token])
    expect(second[:refresh_token]).not_to eq(first[:refresh_token])
    expect(described_class.validate_access_token(second[:access_token]).first).to eq(:valid)
    expect_invalid_grant { described_class.refresh!(client: client, refresh_token: first[:refresh_token]) }
  end

  it "validates in order: unknown is invalid, revoked is invalid, expired is expired" do
    set = exchange(approve)
    expect(described_class.validate_access_token("nope")).to eq([:invalid, nil])
    status, grant = described_class.validate_access_token(set[:access_token])
    expect(status).to eq(:valid)
    expect(grant.operator_seq).to eq(operator.seq)
    advance(301)
    expect(described_class.validate_access_token(set[:access_token])).to eq([:expired, nil])
    described_class.revoke!(grant)
    expect(described_class.validate_access_token(set[:access_token])).to eq([:invalid, nil])
  end

  it "revoking a grant invalidates both its access and refresh tokens" do
    set = exchange(approve)
    grant = MockPms::Grant.active.first
    described_class.revoke!(grant)
    expect(described_class.validate_access_token(set[:access_token])).to eq([:invalid, nil])
    expect_invalid_grant { described_class.refresh!(client: client, refresh_token: set[:refresh_token]) }
  end

  it "reuses the active grant when the same operator approves the same client again" do
    exchange(approve)
    exchange(approve)
    expect(MockPms::Grant.where(client_seq: client.seq, operator_seq: operator.seq).count).to eq(1)
  end

  it "authenticates clients by secret" do
    client_row, secret = Factory.client
    expect(described_class.authenticate_client(client_row.id, secret)).to eq(client_row)
    expect { described_class.authenticate_client(client_row.id, "wrong") }
      .to raise_error(MockPms::OAuth::Error) { |e| expect([e.code, e.status]).to eq(["invalid_client", 401]) }
  end
end
