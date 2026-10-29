# frozen_string_literal: true

require "spec_helper"

# T026, research R11: bcrypt passwords, cookie tokens stored only as SHA-256, idle and absolute
# expiry, sign-out, and per-session CSRF tokens.
RSpec.describe "operator passwords, sessions and CSRF" do
  let(:operator) do
    Rentsync::Operator.create(email: "Ann@Example.test", name: "Ann",
                              password_digest: Rentsync::Auth::Passwords.digest("correct horse battery"))
  end

  describe Rentsync::Auth::Passwords do
    it "stores a bcrypt digest, never the password" do
      expect(operator.password_digest).to start_with("$2")
      expect(operator.password_digest).not_to include("correct horse")
    end

    it "authenticates by email, ignoring case, with the right password only" do
      operator
      expect(described_class.authenticate("ann@example.TEST", "correct horse battery")).to eq(operator)
      expect(described_class.authenticate("ann@example.test", "wrong")).to be_nil
      expect(described_class.authenticate("nobody@example.test", "correct horse battery")).to be_nil
    end

    # Unknown email and wrong password take the same path, so timing does not reveal accounts.
    it "checks a password against a dummy digest when the email is unknown" do
      allow(BCrypt::Password).to receive(:new).and_call_original
      described_class.authenticate("nobody@example.test", "x")
      expect(BCrypt::Password).to have_received(:new).once
    end
  end

  describe Rentsync::Auth::Sessions do
    let(:sessions) { described_class }

    it "issues a 32-byte random token and stores only its SHA-256" do
      token = sessions.create!(operator)
      expect(Base64.urlsafe_decode64(token).bytesize).to eq(32)
      row = Rentsync.db[:sessions].first
      expect(row[:token_sha256].to_s.b).to eq(Digest::SHA256.digest(token))
      expect(row.values.map(&:to_s)).not_to include(token)
    end

    it "finds the session's operator from the token" do
      token = sessions.create!(operator)
      expect(sessions.find(token).operator_id).to eq(operator.id)
      expect(sessions.find("not-a-token")).to be_nil
      expect(sessions.find(nil)).to be_nil
    end

    it "expires after 12 hours idle, and use keeps it alive" do
      freeze_time(Time.utc(2026, 10, 29, 8))
      token = sessions.create!(operator)
      advance(11 * 3600)
      expect(sessions.find(token)).not_to be_nil
      advance(11 * 3600)
      expect(sessions.find(token)).not_to be_nil
      advance((12 * 3600) + 1)
      expect(sessions.find(token)).to be_nil
    end

    it "expires 7 days after sign-in however active it is" do
      freeze_time(Time.utc(2026, 10, 29, 8))
      token = sessions.create!(operator)
      15.times do
        advance(11 * 3600)
        expect(sessions.find(token)).not_to be_nil
      end
      advance(11 * 3600) # 176 h > 7 days
      expect(sessions.find(token)).to be_nil
    end

    it "sets revoked_at on sign-out, after which the token no longer works" do
      token = sessions.create!(operator)
      sessions.revoke!(token)
      expect(Rentsync.db[:sessions].first[:revoked_at]).not_to be_nil
      expect(sessions.find(token)).to be_nil
    end
  end

  describe Rentsync::Auth::Csrf do
    let(:first) { Rentsync::Auth::Sessions.find(Rentsync::Auth::Sessions.create!(operator)) }
    let(:second) { Rentsync::Auth::Sessions.find(Rentsync::Auth::Sessions.create!(operator)) }

    it "gives each session its own token, which only that session accepts" do
      token = described_class.token(first)
      expect(described_class.token(first)).to eq(token)
      expect(described_class.token(second)).not_to eq(token)
      expect(described_class.valid?(first, token)).to be(true)
      expect(described_class.valid?(second, token)).to be(false)
      expect(described_class.valid?(first, nil)).to be(false)
      expect(described_class.valid?(first, "")).to be(false)
    end

    it "compares in constant time" do
      allow(Rack::Utils).to receive(:secure_compare).and_call_original
      described_class.valid?(first, "guess")
      expect(Rack::Utils).to have_received(:secure_compare)
    end
  end

  describe Rentsync::Auth::SignInThrottle do
    it "allows 5 attempts a minute per email, then refuses" do
      results = Array.new(6) { |i| described_class.allow?(email: "ann@example.test", address: "10.0.0.#{i}") }
      expect(results).to eq(([true] * 5) + [false])
    end

    it "allows 5 attempts a minute per IP, whatever the email" do
      results = Array.new(6) { |i| described_class.allow?(email: "user#{i}@example.test", address: "10.0.0.9") }
      expect(results).to eq(([true] * 5) + [false])
    end

    it "treats email case as the same account" do
      5.times { described_class.allow?(email: "ann@example.test", address: "10.0.0.1") }
      expect(described_class.allow?(email: "ANN@example.test", address: "10.0.0.2")).to be(false)
    end
  end
end
