# frozen_string_literal: true

# Test for bootstrap-hcp.rb (runbook §Bootstrap step 2). An in-memory fake of the HCP
# Terraform API stands in for app.terraform.io, so no HCP Terraform account or token is needed. Proves:
#   1. plan mode changes nothing and never asks for a secret;
#   2. --apply on an empty organization builds the project, the variable set, the three
#      workspaces, remote state sharing and every variable in contracts/workspace-variables.md;
#   3. a rerun changes nothing;
#   4. drifted workspace settings are restored, but a variable that exists is never changed;
#   5. secrets: each admin_token differs, none is printed, and a weak password changes nothing;
#   6. the GitHub connection is never guessed;
#   7. --teardown deletes the workspaces (safe delete), the variable set and the project only after
#      confirmation, refuses while a workspace manages resources, and keeps a shared project.
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../bootstrap-hcp"

class FakeHcp
  attr_reader :projects, :varsets, :workspaces, :mutations

  def initialize(oauth_tokens: ["ot-github"], installs: [])
    @projects = {}
    @varsets = {}
    @workspaces = {}
    @oauth_tokens = oauth_tokens
    @installs = installs
    @mutations = []
    @seq = 0
  end

  def ws(name) = @workspaces.fetch(name)
  def var(name, key) = ws(name)[:vars].find { |v| v["attributes"]["key"] == key }

  def get(path)
    case path
    when "/organizations/example-org" then { "data" => { "id" => "example-org" } }
    when %r{\A/organizations/example-org/workspaces/([\w-]+)\z}
      w = @workspaces[Regexp.last_match(1)] or return nil
      { "data" => { "id" => w[:id], "attributes" => w[:attrs],
                    "relationships" => { "project" => { "data" => { "id" => w[:project] } } } } }
    else raise "unexpected GET #{path}"
    end
  end

  def list(path)
    case path
    when %r{/projects\?filter} then @projects.map { |name, id| { "id" => id, "attributes" => { "name" => name } } }
    when %r{/varsets\?q=}
      @varsets.map do |id, v|
        { "id" => id, "attributes" => { "name" => v[:name] },
          "relationships" => { "projects" => { "data" => v[:projects].map { |p| { "id" => p } } } } }
      end
    when %r{\A/varsets/([\w-]+)/relationships/vars\z} then @varsets[Regexp.last_match(1)][:vars]
    when "/organizations/example-org/oauth-clients"
      @oauth_tokens.empty? ? [] : [{ "id" => "oc-1", "attributes" => { "service-provider" => "github" } }]
    when "/oauth-clients/oc-1/oauth-tokens" then @oauth_tokens.map { |t| { "id" => t } }
    when "/github-app/installations" then @installs
    when %r{\A/organizations/example-org/workspaces\?filter%5Bproject%5D%5Bid%5D=([\w-]+)\z}
      @workspaces.select { |_, w| w[:project] == Regexp.last_match(1) }.map { |name, _| { "attributes" => { "name" => name } } }
    when %r{\A/workspaces/([\w-]+)/(vars|relationships/tags|relationships/remote-state-consumers)\z}
      w = by_id(Regexp.last_match(1))
      { "vars" => w[:vars], "relationships/tags" => w[:tags].map { |t| { "attributes" => { "name" => t } } },
        "relationships/remote-state-consumers" => w[:consumers].map { |c| { "id" => c } } }[Regexp.last_match(2)]
    else raise "unexpected list #{path}"
    end
  end

  def post(path, body)
    @mutations << [:post, path]
    data = body && body[:data]
    case path
    when %r{\A/workspaces/([\w-]+)/actions/safe-delete\z}
      w = by_id(Regexp.last_match(1))
      raise HcpBootstrap::Abort, "safe-delete refused: resources under management" if w[:attrs]["resource-count"].to_i.positive?

      @workspaces.delete(@workspaces.key(w))
      {}
    when "/organizations/example-org/projects"
      id = next_id("prj")
      @projects[data[:attributes][:name]] = id
      { "data" => { "id" => id } }
    when "/organizations/example-org/varsets"
      id = next_id("varset")
      @varsets[id] = { name: data[:attributes][:name], projects: data[:relationships][:projects][:data].map { |p| p[:id] },
                       vars: data[:relationships][:vars][:data].map { |v| stored(v) } }
      { "data" => { "id" => id } }
    when %r{\A/varsets/([\w-]+)/relationships/projects\z} then @varsets[Regexp.last_match(1)][:projects] << data.first[:id]
    when %r{\A/varsets/([\w-]+)/relationships/vars\z} then @varsets[Regexp.last_match(1)][:vars] << stored(data)
    when "/organizations/example-org/workspaces"
      id = next_id("ws")
      attrs = data[:attributes].transform_keys(&:to_s)
      @workspaces[attrs.delete("name")] = { id: id, attrs: attrs, project: data[:relationships][:project][:data][:id],
                                            tags: [], vars: [], consumers: [] }
      { "data" => { "id" => id } }
    when %r{\A/workspaces/([\w-]+)/vars\z} then by_id(Regexp.last_match(1))[:vars] << stored(data)
    when %r{\A/workspaces/([\w-]+)/relationships/tags\z} then by_id(Regexp.last_match(1))[:tags] << data.first[:attributes][:name]
    when %r{\A/workspaces/([\w-]+)/relationships/remote-state-consumers\z}
      raise "consumer without an id" unless data.first[:id]

      by_id(Regexp.last_match(1))[:consumers] << data.first[:id]
    else raise "unexpected POST #{path}"
    end
  end

  def delete(path)
    @mutations << [:delete, path]
    case path
    when %r{\A/varsets/([\w-]+)\z} then @varsets.delete(Regexp.last_match(1)) || raise("no varset")
    when %r{\A/projects/([\w-]+)\z}
      raise "project still holds workspaces" if @workspaces.values.any? { |w| w[:project] == Regexp.last_match(1) }

      @projects.delete(@projects.key(Regexp.last_match(1)))
    else raise "unexpected DELETE #{path}"
    end
    {}
  end

  def patch(path, body)
    @mutations << [:patch, path]
    w = by_id(path[%r{\A/workspaces/([\w-]+)\z}, 1] || raise("unexpected PATCH #{path}"))
    w[:attrs].merge!(body[:data][:attributes].transform_keys(&:to_s))
    w[:project] = body[:data][:relationships][:project][:data][:id] if body[:data][:relationships]
    {}
  end

  private

  def next_id(prefix) = "#{prefix}-#{@seq += 1}"
  def by_id(id) = @workspaces.values.find { |w| w[:id] == id } || raise("no workspace #{id}")

  def stored(var)
    { "id" => next_id("var"), "attributes" => var[:attributes].transform_keys(&:to_s) }
  end
end

class BootstrapHcpTest < Minitest::Test
  PASSWORD = "Re$hearsal #0nly-Pw1"
  SETTINGS = { aws_account: "123456789012", ami: "ami-0123456789abcdef0", acme_email: "ops@example.test",
               openobserve_email: "o2@example.test", budget_email: "budget@example.test", hcp_org: "example-org",
               github_repo: "example-owner/example-app", region: "eu-west-2", availability_zone: "eu-west-2b",
               domain: "example.com" }.freeze
  OPTS = SETTINGS.merge(branch: "main").freeze

  def setup
    @hcp = FakeHcp.new
    @tokens = []
  end

  def run_bootstrap(apply:, hcp: @hcp, password: PASSWORD, **extra)
    out = StringIO.new
    token = lambda do
      raise "a token was generated in plan mode" unless apply

      @tokens << SecureRandom.hex(32)
      @tokens.last
    end
    asked = lambda do
      raise "the password was asked for in plan mode" unless apply

      password
    end
    HcpBootstrap::Bootstrap.new(api: hcp, opts: OPTS.merge(apply: apply, **extra), out: out,
                                password: asked, token: token).run
    out.string
  end

  def test_plan_changes_nothing
    out = run_bootstrap(apply: false)
    assert_empty @hcp.mutations
    assert_match(/^\+ create project RentSync$/, out)
    assert_match(/^\+ create workspace rentsync-prod-us \(infra\/terraform\/environment, manual apply, branch main\)$/, out)
    assert_match(/^\+ set rentsync-dev-staging admin_token = sensitive, generated$/, out)
    assert_match(/^\+ share rentsync-shared-us state with rentsync-prod-us$/, out)
    assert_match(/change\(s\) planned\. Nothing was changed/, out)
  end

  def test_apply_builds_everything
    out = run_bootstrap(apply: true)

    project = @hcp.projects.fetch("RentSync")
    varset = @hcp.varsets.values.first
    assert_equal "rentsync-aws", varset[:name]
    assert_equal [project], varset[:projects]
    assert_equal({ "TFC_AWS_PROVIDER_AUTH" => "true", "TFC_AWS_RUN_ROLE_ARN" => "arn:aws:iam::123456789012:role/rentsync-hcp-terraform",
                   "TF_CLOUD_ORGANIZATION" => "example-org" },
                 varset[:vars].to_h { |v| [v["attributes"]["key"], v["attributes"]["value"]] })
    assert(varset[:vars].all? { |v| v["attributes"]["category"] == "env" })

    { "rentsync-shared-us" => ["infra/terraform/shared", false, "rentsync-shared"],
      "rentsync-dev-staging" => ["infra/terraform/environment", true, "rentsync-environment"],
      "rentsync-prod-us" => ["infra/terraform/environment", false, "rentsync-environment"] }.each do |name, (dir, auto, tag)|
      ws = @hcp.ws(name)
      assert_equal project, ws[:project], name
      assert_equal dir, ws[:attrs]["working-directory"], name
      assert_equal auto, ws[:attrs]["auto-apply"], name
      assert_equal "1.16.6", ws[:attrs]["terraform-version"]
      assert_equal ["infra/**"], ws[:attrs]["trigger-patterns"]
      assert ws[:attrs]["file-triggers-enabled"]
      assert_equal({ "identifier" => "example-owner/example-app", "branch" => "main", "oauth-token-id" => "ot-github" }, ws[:attrs]["vcs-repo"])
      refute ws[:attrs].key?("assessments-enabled"), "assessments are opt-in"
      assert_equal [tag], ws[:tags]
    end

    shared = @hcp.ws("rentsync-shared-us")
    assert_equal false, shared[:attrs]["global-remote-state"]
    assert_equal [@hcp.ws("rentsync-dev-staging")[:id], @hcp.ws("rentsync-prod-us")[:id]].sort, shared[:consumers].sort

    expected = {
      "rentsync-shared-us" => { "deployment_id" => "shared-us", "ami_id" => "ami-0123456789abcdef0",
                                "availability_zone" => "eu-west-2b", "telemetry_hostname" => "telemetry.example.com",
                                "region" => "eu-west-2",
                                "telemetry_private_ip" => "10.40.1.10", "acme_email" => "ops@example.test",
                                "acme_ca" => HcpBootstrap::LE_STAGING, "openobserve_root_email" => "o2@example.test",
                                "openobserve_root_password" => PASSWORD, "budget_email" => "budget@example.test" },
      "rentsync-dev-staging" => { "deployment_id" => "dev-staging", "environment" => "staging",
                                  "hostname" => "pms-staging.example.com", "private_ip" => "10.41.1.20",
                                  "vpc_cidr" => "10.41.0.0/16", "subnet_cidr" => "10.41.1.0/24",
                                  "hcp_organization" => "example-org", "region" => "eu-west-2",
                                  "acme_email" => "ops@example.test", "acme_ca" => HcpBootstrap::LE_STAGING,
                                  "admin_token" => @tokens[0] },
      "rentsync-prod-us" => { "deployment_id" => "prod-us", "environment" => "production",
                              "hostname" => "pms.example.com", "private_ip" => "10.42.1.30",
                              "vpc_cidr" => "10.42.0.0/16", "subnet_cidr" => "10.42.1.0/24",
                              "hcp_organization" => "example-org", "region" => "eu-west-2",
                              "acme_email" => "ops@example.test", "acme_ca" => HcpBootstrap::LE_STAGING,
                              "admin_token" => @tokens[1], "protected" => "true" }
    }
    expected.each do |name, vars|
      stored = @hcp.ws(name)[:vars].map { |v| v["attributes"] }
      assert_equal vars, stored.to_h { |a| [a["key"], a["value"]] }, name
      assert(stored.all? { |a| a["category"] == "terraform" })
      assert_equal %w[admin_token openobserve_root_password] & vars.keys, stored.select { |a| a["sensitive"] }.map { |a| a["key"] }
    end

    assert_equal 2, @tokens.uniq.size, "each environment gets its own admin_token"
    assert(@tokens.all? { |t| t.match?(/\A\h{64}\z/) })
    (@tokens + [PASSWORD]).each { |secret| refute_includes out, secret }
    assert_match(/change\(s\) applied\.$/, out)
  end

  def test_rerun_changes_nothing
    run_bootstrap(apply: true)
    before = @hcp.mutations.size
    out = run_bootstrap(apply: true, password: nil)
    assert_equal before, @hcp.mutations.size
    assert_match(/^0 change\(s\) applied\.$/, out)
    assert_equal 2, @tokens.size, "no new admin_token on a rerun"
  end

  def test_drift_restores_settings_but_never_variables
    run_bootstrap(apply: true)
    @hcp.ws("rentsync-dev-staging")[:attrs]["auto-apply"] = false
    production_ca = "https://acme-v02.api.letsencrypt.org/directory"
    @hcp.var("rentsync-prod-us", "acme_ca")["attributes"]["value"] = production_ca
    @hcp.var("rentsync-shared-us", "ami_id")["attributes"]["value"] = "ami-0fedcba9876543210"

    out = run_bootstrap(apply: true)
    assert_equal true, @hcp.ws("rentsync-dev-staging")[:attrs]["auto-apply"]
    assert_match(/^\+ update workspace rentsync-dev-staging: auto-apply$/, out)
    assert_equal production_ca, @hcp.var("rentsync-prod-us", "acme_ca")["attributes"]["value"]
    assert_equal "ami-0fedcba9876543210", @hcp.var("rentsync-shared-us", "ami_id")["attributes"]["value"]
    assert_match(/rentsync-prod-us acme_ca is .*; not changed/, out)
    assert_match(/^1 change\(s\) applied\.$/, out)
  end

  def test_weak_password_changes_nothing
    ["Sh0rt!x", "nouppercase1!", "NoSpecial123", "Has'Quote1x", "Ab1!" * 33].each do |bad|
      hcp = FakeHcp.new
      assert_raises(HcpBootstrap::Abort, bad) { run_bootstrap(apply: true, hcp: hcp, password: bad) }
      assert_empty hcp.mutations, bad
    end
    assert_nil HcpBootstrap.password_problem(PASSWORD)
  end

  def test_branch_and_health_assessments_flags
    run_bootstrap(apply: true, branch: "002-aws-deployment", health_assessments: true)
    ws = @hcp.ws("rentsync-shared-us")
    assert_equal "002-aws-deployment", ws[:attrs]["vcs-repo"]["branch"]
    assert_equal true, ws[:attrs]["assessments-enabled"]

    out = run_bootstrap(apply: true, branch: "main", health_assessments: true)
    assert_match(/^\+ update workspace rentsync-shared-us: vcs-repo$/, out)
    assert_equal "main", @hcp.ws("rentsync-prod-us")[:attrs]["vcs-repo"]["branch"]
  end

  def test_github_connection_is_never_guessed
    none = FakeHcp.new(oauth_tokens: [])
    error = assert_raises(HcpBootstrap::Abort) { run_bootstrap(apply: false, hcp: none) }
    assert_match(/Version control workflow -> GitHub/, error.message)

    two = FakeHcp.new(oauth_tokens: %w[ot-a ot-b])
    assert_raises(HcpBootstrap::Abort) { run_bootstrap(apply: false, hcp: two) }
    run_bootstrap(apply: true, hcp: two, oauth_token_id: "ot-b")
    assert_equal "ot-b", two.ws("rentsync-prod-us")[:attrs]["vcs-repo"]["oauth-token-id"]

    app = FakeHcp.new(oauth_tokens: [], installs: [{ "id" => "ghain-1", "attributes" => { "name" => "example-owner" } },
                                                   { "id" => "ghain-2", "attributes" => { "name" => "someone-else" } }])
    run_bootstrap(apply: true, hcp: app)
    assert_equal "ghain-1", app.ws("rentsync-shared-us")[:attrs]["vcs-repo"]["github-app-installation-id"]
  end

  def test_arguments_are_validated
    opts = HcpBootstrap.parse([], SETTINGS.dup)
    assert_equal "main", opts[:branch]
    refute opts[:apply]
    assert_equal "example-org", opts[:hcp_org]

    # The flags still override the settings.
    flags = %w[--aws-account 210987654321 --ami ami-0fedcba9876543210 --acme-email a@b.c]
    assert_equal({ aws_account: "210987654321", ami: "ami-0fedcba9876543210", acme_email: "a@b.c" },
                 HcpBootstrap.parse(flags, SETTINGS.dup).slice(:aws_account, :ami, :acme_email))

    assert_raises(HcpBootstrap::Abort) { HcpBootstrap.parse(%w[--aws-account 12345], SETTINGS.dup) }
    assert_raises(HcpBootstrap::Abort) { HcpBootstrap.parse(%w[--acme-email not-an-email], SETTINGS.dup) }
    missing_ami = assert_raises(HcpBootstrap::Abort) { HcpBootstrap.parse([], SETTINGS.except(:ami)) }
    assert_match(/--ami/, missing_ami.message)
    { hcp_org: "bad org", github_repo: "no-slash", domain: "Example.COM", region: "useast1",
      availability_zone: "us-west-2a" }.each do |key, bad|
      assert_raises(HcpBootstrap::Abort, key) { HcpBootstrap.parse([], SETTINGS.merge(key => bad)) }
    end
  end

  def test_settings_file_is_read_as_data
    Dir.mktmpdir do |dir|
      file = File.join(dir, "settings.env")
      File.write(file, "# comment\r\nRENTSYNC_HCP_ORG='example-org'\r\nRENTSYNC_AMI_ID=''\nRENTSYNC_FUTURE_KEY='x'\n")
      assert_equal({ hcp_org: "example-org" }, HcpBootstrap.load_settings(file))

      File.write(file, "RENTSYNC_HCP_ORG=$(touch pwned)\n")
      assert_raises(HcpBootstrap::Abort) { HcpBootstrap.load_settings(file) }
      error = assert_raises(HcpBootstrap::Abort) { HcpBootstrap.load_settings(File.join(dir, "missing.env")) }
      assert_match(/bootstrap-init\.sh/, error.message)
    end
  end

  # A deployment bootstrapped before the settings file existed (the reference one) gains only
  # the new variables; nothing it already has is changed.
  def test_upgrade_adds_only_the_new_variables
    run_bootstrap(apply: true)
    added = { varset: "TF_CLOUD_ORGANIZATION", "rentsync-shared-us" => %w[region availability_zone telemetry_hostname],
              "rentsync-dev-staging" => %w[region hcp_organization], "rentsync-prod-us" => %w[region hcp_organization] }
    @hcp.varsets.values.first[:vars].reject! { |v| v["attributes"]["key"] == added[:varset] }
    added.except(:varset).each { |name, keys| @hcp.ws(name)[:vars].reject! { |v| keys.include?(v["attributes"]["key"]) } }
    before = @hcp.workspaces.transform_values { |w| w[:vars].map { |v| v["attributes"].dup } }

    out = run_bootstrap(apply: true, password: nil)
    assert_match(/^8 change\(s\) applied\.$/, out)
    assert_includes @hcp.varsets.values.first[:vars].map { |v| v["attributes"]["key"] }, "TF_CLOUD_ORGANIZATION"
    before.each do |name, vars|
      assert_equal vars, @hcp.ws(name)[:vars].first(vars.size).map { |v| v["attributes"] }, "#{name} changed an existing variable"
    end
    assert_equal 2, @tokens.size, "no new admin_token on an upgrade"
  end

  def run_teardown(confirmed:, hcp: @hcp)
    out = StringIO.new
    asked = []
    result = HcpBootstrap::Bootstrap.new(api: hcp, opts: OPTS.merge(teardown: true), out: out,
                                         confirm: ->(what) { asked << what && confirmed }).teardown
    [result, out.string, asked]
  end

  def test_teardown_deletes_only_after_confirmation
    run_bootstrap(apply: true)
    before = @hcp.mutations.size
    result, out, asked = run_teardown(confirmed: false)
    refute result
    assert_equal before, @hcp.mutations.size, "an unconfirmed teardown changed something"
    assert_equal 1, asked.size, "the operator was not asked"
    assert_match(/^- delete workspace rentsync-prod-us/, out)
    assert_match(/^- delete variable set rentsync-aws$/, out)
    assert_match(/^- delete project RentSync$/, out)

    result, out, = run_teardown(confirmed: true)
    assert result
    assert_empty @hcp.workspaces
    assert_empty @hcp.varsets
    assert_empty @hcp.projects
    assert_match(/kept: the GitHub connection/, out)
    # Workspaces go before the project that holds them, through HCP's safe delete.
    kinds = @hcp.mutations.drop(before).map { |verb, path| "#{verb} #{path[%r{/(actions/safe-delete|varsets|projects)}, 1]}" }
    assert_equal ["post actions/safe-delete"] * 3 + ["delete varsets", "delete projects"], kinds

    result, out, asked = run_teardown(confirmed: true)
    assert result
    assert_match(/^Nothing to delete\.$/, out)
    assert_empty asked, "nothing to delete, so nothing to confirm"
  end

  def test_teardown_refuses_while_a_workspace_manages_resources
    run_bootstrap(apply: true)
    @hcp.ws("rentsync-dev-staging")[:attrs]["resource-count"] = 12
    before = @hcp.mutations.size
    error = assert_raises(HcpBootstrap::Abort) { run_teardown(confirmed: true) }
    assert_match(/Destroy its infrastructure first/, error.message)
    assert_equal before, @hcp.mutations.size
  end

  def test_teardown_keeps_a_project_that_holds_other_workspaces
    run_bootstrap(apply: true)
    project = @hcp.projects.fetch("RentSync")
    @hcp.workspaces["someone-elses"] = { id: "ws-other", attrs: {}, project: project, tags: [], vars: [], consumers: [] }
    _, out, = run_teardown(confirmed: true)
    assert_match(/kept: project RentSync, which also holds someone-elses/, out)
    assert_equal project, @hcp.projects["RentSync"]
    assert_equal ["someone-elses"], @hcp.workspaces.keys
  end

  def test_teardown_without_a_terminal_deletes_nothing
    out = StringIO.new
    stdin = $stdin
    $stdin = StringIO.new("7\n") # not a terminal, even with an answer waiting
    begin
      refute HcpBootstrap.confirm_teardown("everything", out: out)
    ensure
      $stdin = stdin
    end
    assert_match(/permanently deletes everything/, out.string)
    assert_match(/No interactive terminal/, out.string)
  end

  def test_teardown_needs_only_the_organization
    assert HcpBootstrap.parse(%w[--teardown], { hcp_org: "example-org" })[:teardown]
    assert_raises(HcpBootstrap::Abort) { HcpBootstrap.parse(%w[--teardown --apply], SETTINGS.dup) }
  end
end
