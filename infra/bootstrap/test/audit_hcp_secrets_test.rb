# frozen_string_literal: true

# Test for audit-hcp-secrets.rb (SC-004, FR-024). A fake HCP Terraform stands behind the
# transport, so no account or token is needed. Proves:
#   1. clean state and logs pass, every state version and run log is read, pagination is followed;
#   2. a secret value in state, in gzipped user data or in a run log fails, naming where but
#      never printing the value;
#   3. a SecureString value or a managed random_password result in state fails;
#   4. sensitive attributes and literal secret-looking assignments are notes, not failures;
#   5. read-only: every request is a GET (the file has no other method), and the token goes only
#      to HCP Terraform's hosts, not across a redirect elsewhere;
#   6. SSM values: an unreadable secret is reported and checked by attribute only.
require "minitest/autorun"
require "stringio"
require "zlib"
require_relative "../audit-hcp-secrets"

class FakeTransport
  attr_reader :requests

  def initialize(routes)
    @routes = routes
    @requests = []
  end

  def call(uri, headers)
    @requests << [uri.to_s, headers.dup]
    route = @routes[uri.to_s] or return [404, {}, ""]
    route.is_a?(Array) ? route : [200, {}, route.is_a?(String) ? route : JSON.generate(route)]
  end
end

class AuditHcpSecretsTest < Minitest::Test
  API = "https://app.terraform.io/api/v2"
  ORG = "example-org"
  TOKEN = "tok-#{'z' * 30}"
  ADMIN = "a" * 64
  DB = "Db-pass-0123456789"

  def state(resources: [], outputs: {})
    JSON.generate("version" => 4, "resources" => resources, "outputs" => outputs)
  end

  def ssm(name, type, attrs = {})
    { "mode" => "managed", "type" => "aws_ssm_parameter", "name" => name,
      "instances" => [{ "attributes" => { "type" => type, "value" => nil, "value_wo" => nil }.merge(attrs),
                        "sensitive_attributes" => [[{ "type" => "get_attr", "value" => "value" }]] }] }
  end

  def host(user_data)
    { "mode" => "managed", "type" => "aws_instance", "name" => "this", "module" => "module.host",
      "instances" => [{ "attributes" => { "user_data_base64" => user_data } }] }
  end

  CLEAN_LOG = "Terraform will perform the following actions:\n  + value_wo = (write-only attribute)\n" \
              "  + name = \"/rentsync/prod-us/admin_token\"\nApply complete!\n"

  # Each workspace: two pages of state versions (the second via links.next), runs with plan and
  # apply logs. Overrides replace a state or log body.
  def routes(states: {}, logs: {})
    r = { "#{API}/organizations/#{ORG}" => { "data" => { "id" => ORG } } }
    HcpSecretAudit::WORKSPACES.each do |ws|
      r["#{API}/organizations/#{ORG}/workspaces/#{ws}"] = { "data" => { "id" => "ws-#{ws}" } }
      first = "/state-versions?filter%5Bworkspace%5D%5Bname%5D=#{ws}&filter%5Borganization%5D%5Bname%5D=#{ORG}&page%5Bsize%5D=100"
      r[API + first] = { "data" => [sv(ws, 2)], "links" => { "next" => "#{API}/state-versions?page2-#{ws}" } }
      r["#{API}/state-versions?page2-#{ws}"] = { "data" => [sv(ws, 1)], "links" => { "next" => nil } }
      [1, 2].each { |n| r["https://archivist.terraform.io/v1/object/state-#{ws}-#{n}"] = states.fetch("#{ws}-#{n}", state) }
      r["#{API}/workspaces/ws-#{ws}/runs?include=plan%2Capply&page%5Bsize%5D=100"] = {
        "data" => [{ "id" => "run-#{ws}", "relationships" => { "plan" => { "data" => { "id" => "plan-#{ws}" } },
                                                              "apply" => { "data" => { "id" => "apply-#{ws}" } } } }],
        "included" => %w[plan apply].map do |p|
          { "id" => "#{p}-#{ws}", "attributes" => { "log-read-url" => "https://archivist.terraform.io/v1/object/log-#{p}-#{ws}" } }
        end
      }
      %w[plan apply].each { |p| r["https://archivist.terraform.io/v1/object/log-#{p}-#{ws}"] = logs.fetch("#{p}-#{ws}", CLEAN_LOG) }
    end
    r
  end

  def sv(ws, serial)
    { "id" => "sv-#{ws}-#{serial}", "attributes" => { "serial" => serial,
                                                     "hosted-state-download-url" => "https://archivist.terraform.io/v1/object/state-#{ws}-#{serial}" } }
  end

  def audit(transport, values: { "prod-us admin_token" => ADMIN, "shared-us openobserve/db_password" => DB }, missing: {})
    out = StringIO.new
    reader = HcpSecretAudit::Reader.new(TOKEN, transport: transport, pause: ->(_) {})
    ok = HcpSecretAudit::Audit.new(reader: reader, org: ORG, values: values, missing: missing, out: out).run
    [ok, out.string]
  end

  def refute_secrets_in(out)
    [ADMIN, DB, TOKEN].each { |s| refute_includes out, s }
  end

  def test_clean_passes_and_reads_everything
    t = FakeTransport.new(routes(states: { "rentsync-prod-us-2" => state(resources: [ssm("admin_token", "SecureString")]) }))
    ok, out = audit(t)
    assert ok, out
    assert_match(/^PASS: no secret found/, out)
    HcpSecretAudit::WORKSPACES.each { |ws| assert_includes out, "#{ws}: 2 state version(s), 1 run(s), 2 log(s) checked" }
    downloads = t.requests.map(&:first).grep(/archivist/)
    assert_equal 12, downloads.size # 3 workspaces x (2 states + 2 logs)
    refute_secrets_in out
  end

  def test_secret_value_in_state_fails_without_printing_it
    bad = state(resources: [{ "mode" => "managed", "type" => "aws_instance", "name" => "x",
                              "instances" => [{ "attributes" => { "tags" => { "note" => "token #{ADMIN}" } } }] }])
    ok, out = audit(FakeTransport.new(routes(states: { "rentsync-prod-us-1" => bad })))
    refute ok
    assert_includes out, "FAIL  rentsync-prod-us state sv-rentsync-prod-us-1 (serial 1): holds the value of prod-us admin_token"
    assert_match(/^FAIL: 1 finding/, out)
    refute_secrets_in out
  end

  def test_secret_in_gzipped_user_data_fails
    user_data = [Zlib.gzip("#cloud-config\nwrite_files:\n  - content: DB_PASSWORD=#{DB}\n")].pack("m0")
    ok, out = audit(FakeTransport.new(routes(states: { "rentsync-dev-staging-2" => state(resources: [host(user_data)]) })))
    refute ok
    assert_includes out, "holds the value of shared-us openobserve/db_password"
    refute_secrets_in out
  end

  def test_secret_in_run_log_fails_with_line
    log = "Plan: 1 to add\n  + value = \"#{DB}\"\n"
    ok, out = audit(FakeTransport.new(routes(logs: { "apply-rentsync-shared-us" => log })))
    refute ok
    assert_includes out, "FAIL  rentsync-shared-us run run-rentsync-shared-us apply log: line 2 holds the value of shared-us openobserve/db_password"
    refute_secrets_in out
  end

  def test_securestring_value_and_managed_random_fail
    leaky = state(resources: [
                    ssm("postgres_password", "SecureString", "value" => "whatever-it-is"),
                    { "mode" => "managed", "type" => "random_password", "name" => "pg",
                      "instances" => [{ "attributes" => { "result" => "abcdefghijkl" } }] },
                    { "mode" => "data", "type" => "random_password", "name" => "ignored",
                      "instances" => [{ "attributes" => { "result" => "abcdefghijkl" } }] }
                  ])
    ok, out = audit(FakeTransport.new(routes(states: { "rentsync-dev-staging-1" => leaky })), values: {})
    refute ok
    assert_includes out, "aws_ssm_parameter.postgres_password: SecureString attribute value is set"
    assert_includes out, "random_password.pg: result is set"
    refute_includes out, "random_password.ignored"
    refute_includes out, "whatever-it-is"
  end

  def test_sensitive_attributes_and_literals_are_notes
    noted = state(resources: [{ "mode" => "managed", "type" => "aws_db_thing", "name" => "x",
                                "instances" => [{ "attributes" => { "conn" => [{ "secret" => "s" }] },
                                                  "sensitive_attributes" => [[{ "type" => "get_attr", "value" => "conn" },
                                                                              { "type" => "index", "value" => { "value" => 0, "type" => "number" } }]] }] },
                              ssm("image_tag", "String", "value" => "c5ccd8d")],
                  outputs: { "hidden" => { "value" => "x", "sensitive" => true } })
    log = "  + db_password = \"hunter2hunter2\"\n  + api_token = \"(sensitive value)\"\n"
    t = FakeTransport.new(routes(states: { "rentsync-prod-us-1" => noted, "rentsync-prod-us-2" => noted },
                                 logs: { "plan-rentsync-prod-us" => log }))
    ok, out = audit(t, values: {})
    assert ok, out
    assert_includes out, "aws_db_thing.x: attribute conn.0 is marked sensitive and holds a value (in 2 places)"
    assert_includes out, "output hidden is marked sensitive and holds a value"
    assert_includes out, "line 1: db_password is assigned a literal"
    refute_includes out, "api_token"
    refute_includes out, "image_tag"
    refute_includes out, "hunter2"
  end

  def test_only_gets_and_token_only_to_hcp_hosts
    source = File.read(File.expand_path("../audit-hcp-secrets.rb", __dir__))
    assert_equal ["Get"], source.scan(/Net::HTTP::(\w+)/).flatten.uniq
    refute_match(/\.(post|put|patch|delete|request_post|send_request)\b/, source)

    r = routes
    r["https://archivist.terraform.io/v1/object/log-plan-rentsync-prod-us"] =
      [302, { "location" => "https://elsewhere.example.com/blob" }, ""]
    r["https://elsewhere.example.com/blob"] = CLEAN_LOG
    t = FakeTransport.new(r)
    ok, out = audit(t)
    assert ok, out
    t.requests.each do |url, headers|
      host = URI(url).host
      if HcpSecretAudit::TOKEN_HOSTS.include?(host)
        assert_equal "Bearer #{TOKEN}", headers["Authorization"], url
      else
        refute headers.key?("Authorization"), "token sent to #{host}"
      end
    end
    assert(t.requests.any? { |url, _| url.include?("elsewhere") })
  end

  def test_rate_limit_waits_then_retries
    r = routes
    calls = 0
    t = FakeTransport.new(r)
    flaky = lambda do |uri, headers|
      if uri.to_s.end_with?("/organizations/#{ORG}") && (calls += 1) < 3
        [429, { "retry-after" => "2" }, ""]
      else
        t.call(uri, headers)
      end
    end
    waits = []
    reader = HcpSecretAudit::Reader.new(TOKEN, transport: flaky, pause: ->(s) { waits << s })
    assert HcpSecretAudit::Audit.new(reader: reader, org: ORG, values: {}, missing: {}, out: StringIO.new).run
    assert_equal [2.0, 2.0], waits
  end

  def test_unknown_org_and_http_errors_abort
    e = assert_raises(HcpSecretAudit::Abort) { audit(FakeTransport.new({})) }
    assert_match(/organization example-org not found/, e.message)
    r = routes
    r["https://archivist.terraform.io/v1/object/state-rentsync-shared-us-1"] = [403, {}, "denied"]
    e = assert_raises(HcpSecretAudit::Abort) { audit(FakeTransport.new(r)) }
    assert_match(/HTTP 403/, e.message)
    refute_includes e.message, TOKEN
  end

  Status = Struct.new(:ok) do
    def success? = ok
  end

  def test_secret_values_from_ssm
    calls = []
    run = lambda do |*cmd|
      calls << cmd
      name = cmd[cmd.index("--name") + 1]
      case name
      when %r{/admin_token\z} then ["#{ADMIN}\n", "", Status.new(true)]
      when %r{/root_password\z} then ["short\n", "", Status.new(true)]
      else ["", "An error occurred (AccessDeniedException) when calling GetParameter: no", Status.new(false)]
      end
    end
    values, missing = HcpSecretAudit.secret_values(profile: "rentsync", region: "us-east-1", run: run)
    assert_equal({ "dev-staging admin_token" => ADMIN, "prod-us admin_token" => ADMIN }, values)
    assert_equal "AccessDenied", missing["prod-us postgres_password"]
    assert_equal "too short to search for", missing["shared-us openobserve/root_password"]
    assert_equal 7, calls.size
    assert(calls.all? { |c| c.first(3) == %w[aws ssm get-parameter] && c.include?("--with-decryption") })
    assert(calls.all? { |c| c[c.index("--profile") + 1] == "rentsync" })

    out = StringIO.new
    HcpSecretAudit::Audit.new(reader: HcpSecretAudit::Reader.new(TOKEN, transport: FakeTransport.new(routes), pause: ->(_) {}),
                              org: ORG, values: values, missing: missing, out: out).run
    assert_includes out.string, "Searching by value for: dev-staging admin_token, prod-us admin_token"
    assert_includes out.string, "Checked by attribute only (AccessDenied): prod-us postgres_password"
    refute_includes out.string, ADMIN
  end

  def test_parse
    assert_equal({ aws_profile: "rentsync", values: true }, HcpSecretAudit.parse([]))
    assert_equal({ aws_profile: "x", values: false }, HcpSecretAudit.parse(%w[--aws-profile x --no-values]))
    assert_raises(HcpSecretAudit::Abort) { HcpSecretAudit.parse(%w[--apply]) }
    assert_raises(HcpSecretAudit::Abort) { HcpSecretAudit.parse(%w[extra]) }
  end
end
