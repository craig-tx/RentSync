# frozen_string_literal: true

require "spec_helper"

# T028: sign-in, CSRF, the connect callback (with a stubbed PMS token endpoint), reconnecting,
# disconnecting and operator scoping (US1, FR-001, FR-002, FR-007, FR-008, FR-023).
# Requests use https://app.test because the session cookie is Secure off localhost.
RSpec.describe "connections", type: :request do
  def app = Rentsync::App.build

  def base = "https://app.test"

  let(:password) { "operator-password-1" }
  let(:digest) { Rentsync::Auth::Passwords.digest(password) }
  let!(:ann) { Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: digest) }
  let!(:bo) { Rentsync::Operator.create(email: "bo@example.test", name: "Bo", password_digest: digest) }
  let!(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end
  let(:token_calls) { [] }
  let(:pms_operator) { { id: "op_1", name: "Lone Star Rentals" } }

  before do
    calls = token_calls
    who = -> { pms_operator }
    Rentsync::Pms::OAuth.default_request = lambda do |req, _uri|
      calls << URI.decode_www_form(req.body.to_s).to_h
      [200, JSON.generate(access_token: "AT-#{calls.size}", token_type: "Bearer", expires_in: 300,
                          refresh_token: "RT-#{calls.size}", scope: "read",
                          operator_id: who.call[:id], operator_name: who.call[:name])]
    end
  end

  after { Rentsync::Pms::OAuth.default_request = nil }

  def sign_in(email = "ann@example.test", pass = password, from: "203.0.113.5")
    post "#{base}/sign-in", { email: email, password: pass }, { "REMOTE_ADDR" => from }
  end

  def csrf
    get "#{base}/connections"
    last_response.body[/name="csrf_token" value="([^"]+)"/, 1] || raise("no CSRF token on /connections")
  end

  # Starts a connection and returns the state the PMS would echo back.
  def start_connect
    post "#{base}/connections", csrf_token: csrf
    expect(last_response.status).to eq(303)
    URI.decode_www_form(URI(last_response.location).query).to_h.fetch("state")
  end

  def callback(state, **extra) = get("#{base}/connections/callback", { state: state }.merge(extra))

  def connect!(code: "CODE-1")
    callback(start_connect, code: code)
    expect(last_response.status).to eq(303)
    Rentsync::PmsConnection.order(:id).last
  end

  def json_get(path) = get("#{base}#{path}", {}, { "HTTP_ACCEPT" => "application/json" })

  describe "signing in" do
    it "sets a Secure, HttpOnly, SameSite=Lax session cookie and redirects to /connections" do
      sign_in
      expect(last_response.status).to eq(303)
      expect(last_response.location).to end_with("/connections")
      cookie = last_response.headers["set-cookie"]
      expect(cookie).to match(/rentsync_session=/)
      expect(cookie).to match(/httponly/i).and match(/secure/i).and match(/samesite=lax/i)
    end

    describe "refusing cross-site sign-in posts (login CSRF)" do
      def sign_in_with(headers)
        post "#{base}/sign-in", { email: "ann@example.test", password: password },
             { "REMOTE_ADDR" => "203.0.113.5" }.merge(headers)
      end

      it "refuses a post from another site with 403, without a session or a throttle token" do
        [{ "HTTP_ORIGIN" => "https://evil.test" }, { "HTTP_ORIGIN" => "null" },
         { "HTTP_SEC_FETCH_SITE" => "cross-site" }, { "HTTP_SEC_FETCH_SITE" => "same-site" },
         { "HTTP_ORIGIN" => "http://app.test", "HTTP_SEC_FETCH_SITE" => "cross-site" }].each do |headers|
          sign_in_with(headers)
          expect(last_response.status).to eq(403), headers.inspect
          expect(last_response.headers["set-cookie"].to_s).not_to include("rentsync_session=")
        end
        expect(Rentsync.db[:sessions].count).to eq(0)
        sign_in
        expect(last_response.status).to eq(303)
      end

      it "accepts the app's own origin, same-origin and direct requests, and clients that send neither" do
        [{ "HTTP_ORIGIN" => "http://app.test", "HTTP_SEC_FETCH_SITE" => "same-origin" },
         { "HTTP_SEC_FETCH_SITE" => "none" }, {}].each do |headers|
          sign_in_with(headers)
          expect(last_response.status).to eq(303), headers.inspect
        end
      end
    end

    it "gives the same generic error for an unknown email and a wrong password" do
      sign_in("nobody@example.test")
      unknown = [last_response.status, last_response.body[/<p class="error">[^<]*/]]
      sign_in("ann@example.test", "wrong")
      wrong = [last_response.status, last_response.body[/<p class="error">[^<]*/]]
      expect(unknown).to eq(wrong)
      expect(unknown[0]).to eq(200)
      expect(unknown[1]).not_to be_nil
    end

    it "refuses the 6th attempt in a minute for one email with 429" do
      5.times { |i| sign_in("ann@example.test", "wrong", from: "203.0.113.#{i}") }
      sign_in("ann@example.test", password, from: "203.0.113.99")
      expect(last_response.status).to eq(429)
    end

    it "refuses the 6th attempt in a minute from one IP with 429" do
      5.times { |i| sign_in("user#{i}@example.test", "wrong") }
      sign_in
      expect(last_response.status).to eq(429)
    end

    it "sends a request with no session to /sign-in, and /v1 requests get 401" do
      get "#{base}/connections"
      expect(last_response.status).to eq(303)
      expect(last_response.location).to end_with("/sign-in")
      get "#{base}/v1/connections"
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unauthenticated")
    end

    it "signs out: the session is revoked and the cookie no longer works" do
      sign_in
      post "#{base}/sign-out", csrf_token: csrf
      expect(last_response.status).to eq(303)
      expect(Rentsync.db[:sessions].exclude(revoked_at: nil).count).to eq(1)
      get "#{base}/connections"
      expect(last_response.location).to end_with("/sign-in")
    end
  end

  describe "CSRF" do
    before { sign_in }

    it "refuses POST /connections without the token" do
      post "#{base}/connections"
      expect(last_response.status).to eq(403)
      post "#{base}/connections", csrf_token: "forged"
      expect(last_response.status).to eq(403)
      expect(Rentsync.db[:connection_attempts].count).to eq(0)
    end
  end

  describe "connecting" do
    before { sign_in }

    it "redirects to the PMS with a state and an S256 challenge, storing only the state's digest" do
      state = start_connect
      query = URI.decode_www_form(URI(last_response.location).query).to_h
      expect(last_response.location).to start_with("http://pms.test/oauth/authorize?")
      expect(query).to include("code_challenge_method" => "S256", "client_id" => "client_A")
      row = Rentsync.db[:connection_attempts].first
      expect(row[:state_sha256].to_s.b).to eq(Digest::SHA256.digest(state))
      expect(row[:code_verifier]).to start_with("v1:")
      expect(row[:expires_at]).to be_within(1).of(row[:created_at] + 600)
    end

    it "connects on success: active, with the PMS operator's name and the connection time (AC1)" do
      con = connect!
      expect(last_response.location).to include("/connections")
      expect(con).to have_attributes(operator_id: ann.id, pms_operator_id: "op_1", status: "active",
                                     pms_operator_name: "Lone Star Rentals")
      expect(con.connected_at).not_to be_nil
      expect(con.access_token_plaintext).to eq("AT-1")
      expect(token_calls.last).to include("grant_type" => "authorization_code", "code" => "CODE-1")
      expect(token_calls.last["code_verifier"]).not_to be_empty
      expect(Rentsync.db[:connection_attempts].first).to include(outcome: "connected")
      follow_redirect!
      expect(last_response.body).to include("Lone Star Rentals", "active")
    end

    it "escapes the PMS operator's name on the page" do
      pms_operator[:name] = "<script>x</script>"
      connect!
      get "#{base}/connections"
      expect(last_response.body).not_to include("<script>x</script>")
      expect(last_response.body).to include("&lt;script&gt;")
    end

    it "records a denial and stores nothing else (AC2)" do
      callback(start_connect, error: "access_denied")
      expect(last_response.status).to eq(303)
      expect(Rentsync::PmsConnection.count).to eq(0)
      expect(Rentsync.db[:connection_attempts].first).to include(outcome: "denied", error_code: "access_denied")
      follow_redirect!
      expect(last_response.body).to include("access was denied")
      expect(token_calls).to be_empty
    end

    {
      "an unknown state" => ->(_state) { "not-a-state" },
      "a missing state" => ->(_state) { "" }
    }.each do |name, pick|
      it "refuses #{name} with 400 and stores nothing" do
        state = start_connect
        callback(pick.call(state), code: "CODE-1")
        expect(last_response.status).to eq(400)
        expect(Rentsync::PmsConnection.count).to eq(0)
        expect(token_calls).to be_empty
      end
    end

    it "refuses a used state with 400" do
      state = start_connect
      callback(state, code: "CODE-1")
      callback(state, code: "CODE-1")
      expect(last_response.status).to eq(400)
      expect(token_calls.size).to eq(1)
    end

    it "refuses an expired state with 400 and marks the attempt expired" do
      freeze_time(Time.now.utc)
      state = start_connect
      advance(601)
      callback(state, code: "CODE-1")
      expect(last_response.status).to eq(400)
      expect(Rentsync::PmsConnection.count).to eq(0)
      expect(Rentsync.db[:connection_attempts].first).to include(outcome: "expired")
    end

    it "refuses another operator's state with 400" do
      state = start_connect
      sign_in("bo@example.test")
      callback(state, code: "CODE-1")
      expect(last_response.status).to eq(400)
      expect(Rentsync::PmsConnection.count).to eq(0)
      expect(token_calls).to be_empty
    end

    it "records a failed exchange without storing a connection" do
      Rentsync::Pms::OAuth.default_request = ->(_req, _uri) { [400, JSON.generate(error: "invalid_grant")] }
      callback(start_connect, code: "CODE-1")
      expect(last_response.status).to eq(303)
      expect(Rentsync::PmsConnection.count).to eq(0)
      expect(Rentsync.db[:connection_attempts].first).to include(outcome: "failed", error_code: "invalid_grant")
    end

    it "never logs the code or the state" do
      io = StringIO.new
      original = Rentsync::Logging.io
      Rentsync::Logging.io = io
      state = start_connect
      callback(state, code: "CODE-SECRET-1")
      expect(io.string).not_to include("CODE-SECRET-1", state)
    ensure
      Rentsync::Logging.io = original
    end
  end

  describe "reconnecting and ownership" do
    before { sign_in }

    it "reuses the same connection row after needs_reauth (FR-008)" do
      first = connect!
      first.update(status: "needs_reauth")
      second = connect!(code: "CODE-2")
      expect(second.id).to eq(first.id)
      expect(second.status).to eq("active")
      expect(second.access_token_plaintext).to eq("AT-2")
      expect(Rentsync::PmsConnection.count).to eq(1)
    end

    it "refuses a PMS operator already connected to another RentSync operator" do
      connect!
      sign_in("bo@example.test")
      callback(start_connect, code: "CODE-2")
      expect(last_response.status).to eq(303)
      expect(Rentsync::PmsConnection.count).to eq(1)
      expect(Rentsync.db[:connection_attempts].order(:id).last)
        .to include(outcome: "failed", error_code: "pms_operator_taken")
      follow_redirect!
      expect(last_response.body).to include("already connected")
    end

    it "refuses a second, different PMS account for the same operator" do
      connect!
      pms_operator.replace(id: "op_2", name: "Prairie Homes")
      callback(start_connect, code: "CODE-2")
      expect(last_response.status).to eq(303)
      expect(Rentsync::PmsConnection.select_map(:pms_operator_id)).to eq(["op_1"])
      expect(Rentsync.db[:connection_attempts].order(:id).last)
        .to include(outcome: "failed", error_code: "different_pms_account")
    end
  end

  describe "disconnecting (AC5)" do
    before { sign_in }

    it "nulls both tokens, sets disconnected, and keeps the raw events" do
      con = connect!
      body = JSON.generate("id" => "evt_1")
      Rentsync.db[:raw_events].insert(
        pms_client_id: con.pms_client_id, connection_id: con.id, event_id: "evt_1", event_type: "lease.updated",
        occurred_at: Time.now.utc, received_at: Time.now.utc, arrival_path: "webhook",
        payload_raw: Sequel.blob(body), payload: Sequel.pg_jsonb_wrap(JSON.parse(body)),
        payload_sha256: Sequel.blob(Digest::SHA256.digest(body)), correlation_id: "corr"
      )
      post "#{base}/connections/#{con.public_id}/disconnect", csrf_token: csrf
      expect(last_response.status).to eq(303)
      con.refresh
      expect([con.status, con.access_token, con.refresh_token]).to eq(["disconnected", nil, nil])
      expect(con.disconnected_at).not_to be_nil
      expect(Rentsync.db[:raw_events].where(connection_id: con.id).count).to eq(1)
    end

    it "requires the CSRF token" do
      con = connect!
      post "#{base}/connections/#{con.public_id}/disconnect"
      expect(last_response.status).to eq(403)
      expect(con.refresh.status).to eq("active")
    end
  end

  describe "scoping (AC6, FR-023)" do
    it "shows each operator only their own connections, and 404s the other's" do
      sign_in
      con = connect!

      sign_in("bo@example.test")
      get "#{base}/connections"
      expect(last_response.body).not_to include("Lone Star Rentals")
      json_get("/connections")
      expect(JSON.parse(last_response.body)).to eq("data" => [])
      json_get("/v1/connections")
      expect(JSON.parse(last_response.body)).to eq("data" => [])
      post "#{base}/connections/#{con.public_id}/disconnect", csrf_token: csrf
      expect(last_response.status).to eq(404)
      expect(con.refresh.status).to eq("active")
      # The health page's 404 for another operator is asserted with US4.
    end

    it "serves the operator's own connections as JSON per the Connection schema" do
      sign_in
      con = connect!
      json_get("/v1/connections")
      data = JSON.parse(last_response.body).fetch("data")
      expect(data).to eq([{ "id" => con.public_id, "pms" => "mock_pms", "pms_operator_name" => "Lone Star Rentals",
                            "status" => "active", "connected_at" => con.connected_at.utc.iso8601,
                            "disconnected_at" => nil }])
    end
  end
end
