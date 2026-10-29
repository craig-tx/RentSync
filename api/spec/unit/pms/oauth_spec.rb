# frozen_string_literal: true

require "spec_helper"

# T027, research R7 and data-model.md's renewal rules: the authorize URL, the code exchange,
# and renewal under a lease, with the state machine's transitions.
RSpec.describe Rentsync::Pms::OAuth do
  let(:sent) { [] }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end

  def token_body(access: "AT-NEW", refresh: "RT-NEW")
    JSON.generate(access_token: access, token_type: "Bearer", expires_in: 300, refresh_token: refresh,
                  scope: "read", operator_id: "op_1", operator_name: "Lone Star Rentals")
  end

  # Records each request and answers from `responses` in turn (a Proc raises or answers).
  def transport(*responses)
    queue = responses.dup
    lambda do |req, uri|
      sent << { url: uri.to_s, auth: req["Authorization"], form: URI.decode_www_form(req.body.to_s).to_h }
      answer = queue.length > 1 ? queue.shift : queue.first
      answer.is_a?(Proc) ? answer.call : answer
    end
  end

  def oauth(*responses) = described_class.new(client: pms_client, request: transport(*responses))

  describe "#authorize_url" do
    it "carries the code flow parameters and the S256 challenge, on PMS_PUBLIC_URL" do
      url = URI(oauth.authorize_url(state: "STATE-1", code_verifier: "VERIFIER-1"))
      expect("#{url.scheme}://#{url.host}#{url.path}").to eq("http://pms.test/oauth/authorize")
      query = URI.decode_www_form(url.query).to_h
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest("VERIFIER-1"), padding: false)
      expect(query).to eq("response_type" => "code", "client_id" => "client_A",
                          "redirect_uri" => "http://app.test/connections/callback", "scope" => "read",
                          "state" => "STATE-1", "code_challenge" => challenge, "code_challenge_method" => "S256")
    end
  end

  describe "#exchange_code" do
    it "posts the code, verifier and redirect URI to PMS_API_URL with the client credentials" do
      tokens = oauth([200, token_body]).exchange_code(code: "CODE-1", code_verifier: "VERIFIER-1")
      expect(sent.last[:url]).to eq("http://pms-api.test/oauth/token")
      expect(sent.last[:auth]).to eq("Basic #{Base64.strict_encode64('client_A:CS-A')}")
      expect(sent.last[:form]).to eq("grant_type" => "authorization_code", "code" => "CODE-1",
                                     "code_verifier" => "VERIFIER-1",
                                     "redirect_uri" => "http://app.test/connections/callback")
      expect(tokens).to have_attributes(access_token: "AT-NEW", refresh_token: "RT-NEW", expires_in: 300,
                                        pms_operator_id: "op_1", pms_operator_name: "Lone Star Rentals")
    end

    it "reports an OAuth refusal by its error code only" do
      body = JSON.generate(error: "invalid_grant", error_description: "PKCE verification failed")
      expect { oauth([400, body]).exchange_code(code: "C", code_verifier: "V") }
        .to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("invalid_grant") }
    end

    it "treats 5xx and network errors as temporary" do
      expect { oauth([503, "busy"]).exchange_code(code: "C", code_verifier: "V") }
        .to raise_error(described_class::Unavailable)
      expect { oauth(-> { raise Net::ReadTimeout }).exchange_code(code: "C", code_verifier: "V") }
        .to raise_error(described_class::Unavailable)
      expect { oauth(-> { raise Errno::ECONNREFUSED }).exchange_code(code: "C", code_verifier: "V") }
        .to raise_error(described_class::Unavailable)
    end
  end

  describe Rentsync::Pms::Renewal do
    let(:operator) { Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x") }

    def connection(expires_in:, status: "active")
      Rentsync::PmsConnection.create_with_secrets(
        { operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
          pms_operator_name: "Lone Star Rentals", status: status, connected_at: Rentsync::Clock.now,
          access_expires_at: Rentsync::Clock.now + expires_in },
        access_token: "AT-OLD", refresh_token: "RT-OLD"
      )
    end

    def renewal(*responses) = described_class.new(request: transport(*responses))

    before { freeze_time(Time.utc(2026, 10, 29, 12)) }

    it "uses the stored token while it has more than 60 s left" do
      con = connection(expires_in: 61)
      expect(renewal([200, token_body]).access_token!(con)).to eq("AT-OLD")
      expect(sent).to be_empty
    end

    it "renews with the refresh token when under 60 s remain, and stores the new pair" do
      con = connection(expires_in: 59)
      expect(renewal([200, token_body]).access_token!(con)).to eq("AT-NEW")
      expect(sent.last[:form]).to eq("grant_type" => "refresh_token", "refresh_token" => "RT-OLD")
      con.refresh
      expect([con.access_token_plaintext, con.refresh_token_plaintext]).to eq(%w[AT-NEW RT-NEW])
      expect(con.access_expires_at).to eq(Rentsync::Clock.now + 300)
      expect(con.renewal_lease_until).to be_nil
      expect(con.status).to eq("active")
    end

    %w[invalid_grant invalid_client].each do |code|
      it "sends the connection to needs_reauth on #{code}, and stops calling the PMS" do
        con = connection(expires_in: 0)
        status = code == "invalid_client" ? 401 : 400
        r = renewal([status, JSON.generate(error: code)])
        expect { r.access_token!(con) }.to raise_error(described_class::NeedsReauth)
        con.refresh
        expect(con.status).to eq("needs_reauth")
        expect(con.last_renewal_error).to eq(code)
        expect { r.access_token!(con) }.to raise_error(described_class::NeedsReauth)
        expect(sent.size).to eq(1)
      end
    end

    {
      "a timeout" => -> { raise Net::ReadTimeout },
      "a 5xx" => [502, "bad gateway"],
      "a connection error" => -> { raise Errno::ECONNRESET }
    }.each do |name, answer|
      it "marks renewal_failing on #{name}, backs off, then returns to active on success" do
        con = connection(expires_in: 0)
        r = renewal(answer, [200, token_body])
        expect { r.access_token!(con) }.to raise_error(described_class::Unavailable)
        con.refresh
        expect(con.status).to eq("renewal_failing")
        expect(con.renewal_failures).to eq(1)
        expect(con.renewal_lease_until).to be > Rentsync::Clock.now # the backoff

        # Inside the backoff nobody calls the PMS.
        expect { r.access_token!(con) }.to raise_error(described_class::Unavailable)
        expect(sent.size).to eq(1)

        advance(described_class.backoff_s(1) + 1)
        expect(r.access_token!(con)).to eq("AT-NEW")
        con.refresh
        expect([con.status, con.renewal_failures, con.last_renewal_error]).to eq(["active", 0, nil])
      end
    end

    it "backs off exponentially, capped" do
      expect((1..8).map { |n| described_class.backoff_s(n) }).to eq([5, 10, 20, 40, 80, 160, 300, 300])
    end

    it "never calls the PMS for a connection that needs reauthorization or is disconnected" do
      %w[needs_reauth disconnected].each do |status|
        con = connection(expires_in: 0, status: status)
        expect { renewal([200, token_body]).access_token!(con) }.to raise_error(described_class::NeedsReauth)
        con.destroy
      end
      expect(sent).to be_empty
    end

    it "never logs a token" do
      io = StringIO.new
      original = Rentsync::Logging.io
      Rentsync::Logging.io = io
      renewal([200, token_body]).access_token!(connection(expires_in: 0))
      expect(io.string).not_to include("AT-", "RT-")
    ensure
      Rentsync::Logging.io = original
    end
  end

  # FR-005: two instances needing a token at once make one PMS call; the loser waits for the
  # winner and rereads the row.
  describe "concurrent renewals", :committed do
    it "make exactly one PMS call and both get the new token" do
      operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
      con = Rentsync::PmsConnection.create_with_secrets(
        { operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_1",
          pms_operator_name: "Lone Star Rentals", status: "active", connected_at: Time.now.utc,
          access_expires_at: Time.now.utc - 1 },
        access_token: "AT-OLD", refresh_token: "RT-OLD"
      )
      slow = lambda { |req, uri|
        sleep 0.5
        transport([200, token_body]).call(req, uri)
      }
      sent # memoized before the threads share it
      results = Array.new(2) do
        Thread.new { Rentsync::Pms::Renewal.new(request: slow).access_token!(Rentsync::PmsConnection[con.id]) }
      end.map(&:value)
      expect(results).to eq(%w[AT-NEW AT-NEW])
      expect(sent.size).to eq(1)
    end
  end
end
