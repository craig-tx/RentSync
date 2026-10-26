#!/usr/bin/env ruby
# frozen_string_literal: true

# Runbook §Bootstrap steps 4–6 (feature 002): the HCP Terraform project, the rentsync-aws
# variable set, the three workspaces, remote state sharing and every workspace variable, through
# the HCP Terraform API (contracts/workspace-variables.md).
#
#   ruby infra/bootstrap/bootstrap-hcp.rb --aws-account ID --ami AMI --acme-email E \
#     --openobserve-email E --budget-email E        print the plan; changes nothing
#   ... --apply                                      make the changes
#
# Sign in first with `terraform login`. The token is read from Terraform's credentials file (or
# TF_TOKEN_app_terraform_io) and never printed. Under --apply, each admin_token is generated here
# and sent straight to HCP, and the OpenObserve root password is asked for without echo, so no
# secret is shown, pasted or written to a file.
#
# Safe to rerun. Workspace settings are brought back to the values below, but a variable that
# exists is never changed: the operator changes those later on purpose (acme_ca after the first
# deploy, ami_id, rotations), so a difference is only reported.
require "json"
require "net/http"
require "optparse"
require "securerandom"
require "uri"

module HcpBootstrap
  ORG = "craig-personal"
  PROJECT = "RentSync"
  VARSET = "rentsync-aws"
  REPO = "craig-tx/RentSync"
  TERRAFORM_VERSION = "1.16.6"
  TRIGGER_PATTERNS = ["infra/**"].freeze
  LE_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
  SHARED = "rentsync-shared-us"
  WORKSPACES = [
    { name: SHARED, dir: "infra/terraform/shared", auto_apply: false, tag: "rentsync-shared" },
    { name: "rentsync-dev-staging", dir: "infra/terraform/environment", auto_apply: true, tag: "rentsync-environment" },
    { name: "rentsync-prod-us", dir: "infra/terraform/environment", auto_apply: false, tag: "rentsync-environment" }
  ].freeze

  class Abort < StandardError; end

  # Terraform's own rule for openobserve_root_password (infra/terraform/shared/variables.tf).
  def self.password_problem(password)
    return "must be 8-128 characters" unless password.length.between?(8, 128)
    return "needs a lowercase letter" unless password.match?(/[a-z]/)
    return "needs an uppercase letter" unless password.match?(/[A-Z]/)
    return "needs a digit" unless password.match?(/[0-9]/)
    return "needs a special character" unless password.match?(/[^a-zA-Z0-9]/)
    return "must not contain a single quote or newline" if password.include?("'") || password.include?("\n")

    nil
  end

  def self.ask_password
    require "io/console"
    console = IO.console
    unless console && $stdin.tty?
      raise Abort, "no console for the hidden password prompt; run --apply from PowerShell or Windows Terminal"
    end

    first = console.getpass("OpenObserve root password (not shown): ")
    raise Abort, "the two passwords differ" unless console.getpass("Again: ") == first

    first
  end

  def self.load_token
    token = ENV.fetch("TF_TOKEN_app_terraform_io", "")
    return token unless token.empty?

    dir = Gem.win_platform? ? File.join(ENV.fetch("APPDATA", ""), "terraform.d") : File.join(Dir.home, ".terraform.d")
    file = File.join(dir, "credentials.tfrc.json")
    token = File.exist?(file) && JSON.parse(File.read(file)).dig("credentials", "app.terraform.io", "token")
    token || raise(Abort, "not signed in to HCP Terraform; run `terraform login` first")
  end

  # JSON:API client for app.terraform.io. Errors carry HCP's messages, never the token.
  class Api
    BASE = "https://app.terraform.io/api/v2"

    def initialize(token)
      @token = token
    end

    def get(path) = request(:get, path)
    def post(path, body) = request(:post, path, body)
    def patch(path, body) = request(:patch, path, body)

    # Every item of a list endpoint, following pagination; [] when the endpoint is absent.
    def list(path)
      items = []
      url = path
      while url
        page = get(url) or return items
        items.concat(page["data"])
        url = page.dig("links", "next")
      end
      items
    end

    private

    def request(verb, path, body = nil)
      uri = URI(path.start_with?("https://") ? path : BASE + path)
      req = Net::HTTP.const_get(verb.capitalize).new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/vnd.api+json"
      req.body = JSON.generate(body) if body
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
      return nil if verb == :get && res.code == "404"
      raise Abort, "#{verb.upcase} #{uri.path}: HTTP #{res.code} #{detail(res.body)}" unless res.code.start_with?("2")

      res.body.to_s.empty? ? {} : JSON.parse(res.body)
    end

    def detail(body)
      JSON.parse(body.to_s)["errors"].map { |e| e["detail"] || e["title"] }.join("; ")
    rescue StandardError
      ""
    end
  end

  class Bootstrap
    def initialize(api:, opts:, out: $stdout, password: -> { HcpBootstrap.ask_password },
                   token: -> { SecureRandom.hex(32) })
      @api = api
      @opts = opts
      @out = out
      @password_source = password
      @token_source = token
      @apply = opts[:apply]
      @changes = 0
      @workspace_attrs = {}
    end

    def run
      @api.get("/organizations/#{ORG}") or raise Abort, "organization #{ORG} not found, or the token can't see it"
      password_first
      say "Plan (#{@apply ? 'apply' : 'plan'}):"
      project = ensure_project
      ensure_varset(project)
      vcs = vcs_connection
      ids = WORKSPACES.to_h { |ws| [ws[:name], ensure_workspace(ws, project, vcs)] }
      ensure_remote_state(ids)
      WORKSPACES.each { |ws| ensure_variables(ws, ids[ws[:name]]) }
      say ""
      say(@apply ? "#{@changes} change(s) applied." : "#{@changes} change(s) planned. Nothing was changed; rerun with --apply to make them.")
    end

    private

    def say(line) = @out.puts(line)
    def note(line) = say("  #{line}")

    # Prints a change, and makes it under --apply. Returns the block's result, or nil in plan mode.
    def step(description)
      @changes += 1
      say "+ #{description}"
      yield if @apply
    end

    # Asks for the password before any change, so a typo or weak password changes nothing.
    def password_first
      return unless @apply

      shared = @api.get("/organizations/#{ORG}/workspaces/#{SHARED}")
      return if shared && @api.list("/workspaces/#{shared['data']['id']}/vars").any? { |v| v.dig("attributes", "key") == "openobserve_root_password" }

      @password = @password_source.call
      problem = HcpBootstrap.password_problem(@password)
      raise Abort, "OpenObserve root password #{problem}; nothing was changed" if problem
    end

    def ensure_project
      found = @api.list("/organizations/#{ORG}/projects?filter%5Bnames%5D=#{PROJECT}")
                  .find { |p| p.dig("attributes", "name") == PROJECT }
      if found
        note "project #{PROJECT} exists"
        return found["id"]
      end
      step("create project #{PROJECT}") do
        @api.post("/organizations/#{ORG}/projects", { data: { type: "projects", attributes: { name: PROJECT } } })["data"]["id"]
      end
    end

    def varset_vars
      [{ key: "TFC_AWS_PROVIDER_AUTH", value: "true" },
       { key: "TFC_AWS_RUN_ROLE_ARN", value: "arn:aws:iam::#{@opts[:aws_account]}:role/rentsync-hcp-terraform" }]
    end

    def var_payload(var, category, value = var[:value])
      { type: "vars", attributes: { key: var[:key], value: value, category: category, hcl: false, sensitive: !!var[:sensitive] } }
    end

    def ensure_varset(project)
      found = @api.list("/organizations/#{ORG}/varsets?q=#{VARSET}").find { |v| v.dig("attributes", "name") == VARSET }
      unless found
        step("create variable set #{VARSET} (env #{varset_vars.map { |v| v[:key] }.join(', ')}), applied to project #{PROJECT}") do
          @api.post("/organizations/#{ORG}/varsets", { data: {
                      type: "varsets",
                      attributes: { name: VARSET, description: "AWS sign-in for RentSync workspaces (runbook §Bootstrap)", global: false },
                      relationships: { projects: { data: [{ type: "projects", id: project }] },
                                       vars: { data: varset_vars.map { |v| var_payload(v, "env") } } }
                    } })
        end
        return
      end

      note "variable set #{VARSET} exists"
      attached = (found.dig("relationships", "projects", "data") || []).map { |p| p["id"] }
      unless project && attached.include?(project)
        step("apply variable set #{VARSET} to project #{PROJECT}") do
          @api.post("/varsets/#{found['id']}/relationships/projects", { data: [{ type: "projects", id: project }] })
        end
      end
      existing = @api.list("/varsets/#{found['id']}/relationships/vars")
      varset_vars.each do |var|
        reconcile(var, existing, "variable set #{VARSET}") do
          @api.post("/varsets/#{found['id']}/relationships/vars", { data: var_payload(var, "env") })
        end
      end
    end

    # The GitHub connection workspaces use: a flag, else the one GitHub OAuth connection or
    # GitHub App installation the organization has. Never guessed.
    def vcs_connection
      return { "oauth-token-id" => @opts[:oauth_token_id] } if @opts[:oauth_token_id]
      return { "github-app-installation-id" => @opts[:github_app_installation_id] } if @opts[:github_app_installation_id]

      clients = @api.list("/organizations/#{ORG}/oauth-clients")
                    .select { |c| c.dig("attributes", "service-provider").to_s.start_with?("github") }
      tokens = clients.flat_map { |c| @api.list("/oauth-clients/#{c['id']}/oauth-tokens") }
      return { "oauth-token-id" => tokens.first["id"] } if tokens.size == 1

      owner = REPO.split("/").first
      installs = tokens.empty? ? @api.list("/github-app/installations").select { |i| i.dig("attributes", "name") == owner } : []
      return { "github-app-installation-id" => installs.first["id"] } if installs.size == 1

      raise Abort, <<~MSG.chomp
        found #{tokens.size} GitHub OAuth connection(s) and #{installs.size} GitHub App installation(s) for #{owner}; need exactly one.
          To connect GitHub once: in HCP Terraform choose New -> Workspace -> Version control workflow -> GitHub,
          authorize and install the app for #{owner}, then cancel before creating the workspace.
          Or pass --oauth-token-id ot-... or --github-app-installation-id ghain-...
      MSG
    end

    def desired_settings(ws, vcs)
      settings = {
        "working-directory" => ws[:dir],
        "auto-apply" => ws[:auto_apply],
        "terraform-version" => TERRAFORM_VERSION,
        "file-triggers-enabled" => true,
        "trigger-patterns" => TRIGGER_PATTERNS,
        "vcs-repo" => { "identifier" => REPO, "branch" => @opts[:branch] }.merge(vcs)
      }
      settings["assessments-enabled"] = true if @opts[:health_assessments]
      settings
    end

    def ensure_workspace(ws, project, vcs)
      name = ws[:name]
      desired = desired_settings(ws, vcs)
      found = @api.get("/organizations/#{ORG}/workspaces/#{name}")
      if found.nil?
        id = step("create workspace #{name} (#{ws[:dir]}, #{ws[:auto_apply] ? 'auto apply' : 'manual apply'}, branch #{@opts[:branch]})") do
          @api.post("/organizations/#{ORG}/workspaces", { data: {
                      type: "workspaces", attributes: { name: name }.merge(desired),
                      relationships: { project: { data: { type: "projects", id: project } } }
                    } })["data"]["id"]
        end
        @workspace_attrs[name] = {}
        step("tag workspace #{name} #{ws[:tag]}") { add_tag(id, ws[:tag]) }
        return id
      end

      id = found["data"]["id"]
      attrs = found["data"]["attributes"]
      @workspace_attrs[name] = attrs
      note "workspace #{name} exists"
      drift = desired.reject { |key, value| key == "vcs-repo" ? same_repo?(attrs[key], value) : attrs[key] == value }
      in_project = found.dig("data", "relationships", "project", "data", "id") == project
      unless drift.empty? && in_project
        changed = drift.keys + (in_project ? [] : ["project"])
        step("update workspace #{name}: #{changed.join(', ')}") do
          body = { data: { type: "workspaces", attributes: drift } }
          body[:data][:relationships] = { project: { data: { type: "projects", id: project } } } unless in_project
          @api.patch("/workspaces/#{id}", body)
        end
      end
      tags = @api.list("/workspaces/#{id}/relationships/tags").map { |t| t.dig("attributes", "name") }
      step("tag workspace #{name} #{ws[:tag]}") { add_tag(id, ws[:tag]) } unless tags.include?(ws[:tag])
      id
    end

    def same_repo?(current, desired)
      current.is_a?(Hash) && current["identifier"] == desired["identifier"] && current["branch"] == desired["branch"]
    end

    def add_tag(id, tag)
      @api.post("/workspaces/#{id}/relationships/tags", { data: [{ type: "tags", attributes: { name: tag } }] })
    end

    # Only the two environment workspaces may read the shared outputs (runbook step 5).
    def ensure_remote_state(ids)
      shared = ids[SHARED]
      unless @workspace_attrs[SHARED]["global-remote-state"] == false
        step("share #{SHARED} state with specific workspaces only") do
          @api.patch("/workspaces/#{shared}", { data: { type: "workspaces", attributes: { "global-remote-state" => false } } })
        end
      end
      consumers = shared ? @api.list("/workspaces/#{shared}/relationships/remote-state-consumers").map { |w| w["id"] } : []
      (WORKSPACES.map { |w| w[:name] } - [SHARED]).each do |name|
        next if ids[name] && consumers.include?(ids[name])

        step("share #{SHARED} state with #{name}") do
          @api.post("/workspaces/#{shared}/relationships/remote-state-consumers", { data: [{ type: "workspaces", id: ids[name] }] })
        end
      end
    end

    def workspace_vars(name)
      common = [{ key: "acme_email", value: @opts[:acme_email] }, { key: "acme_ca", value: LE_STAGING }]
      case name
      when SHARED
        [{ key: "deployment_id", value: "shared-us" }, { key: "ami_id", value: @opts[:ami] },
         { key: "telemetry_private_ip", value: "10.40.1.10" }, *common,
         { key: "openobserve_root_email", value: @opts[:openobserve_email] },
         { key: "openobserve_root_password", sensitive: :password },
         { key: "budget_email", value: @opts[:budget_email] }]
      when "rentsync-dev-staging"
        [{ key: "deployment_id", value: "dev-staging" }, { key: "environment", value: "staging" },
         { key: "hostname", value: "pms-staging.rentsync.org" }, { key: "private_ip", value: "10.40.1.20" },
         *common, { key: "admin_token", sensitive: :token }]
      else
        [{ key: "deployment_id", value: "prod-us" }, { key: "environment", value: "production" },
         { key: "hostname", value: "pms.rentsync.org" }, { key: "private_ip", value: "10.40.1.30" },
         *common, { key: "admin_token", sensitive: :token }, { key: "protected", value: "true" }]
      end
    end

    def ensure_variables(ws, id)
      existing = id ? @api.list("/workspaces/#{id}/vars") : []
      workspace_vars(ws[:name]).each do |var|
        reconcile(var, existing, ws[:name]) do
          value = case var[:sensitive]
                  when :token then @token_source.call
                  when :password then @password
                  else var[:value]
                  end
          @api.post("/workspaces/#{id}/vars", { data: var_payload(var, "terraform", value) })
        end
      end
    end

    # Creates a missing variable; reports, but never changes, one that exists.
    def reconcile(var, existing, where)
      current = existing.find { |v| v.dig("attributes", "key") == var[:key] }
      if current.nil?
        how = { token: "sensitive, generated", password: "sensitive, from the prompt" }[var[:sensitive]] || var[:value].inspect
        step("set #{where} #{var[:key]} = #{how}") { yield }
      elsif !var[:sensitive] && current.dig("attributes", "value") != var[:value]
        note "#{where} #{var[:key]} is #{current.dig('attributes', 'value').inspect}, not #{var[:value].inspect}; not changed"
      end
    end
  end

  def self.parse(argv)
    opts = { branch: "main", apply: false }
    OptionParser.new do |o|
      o.banner = "usage: bootstrap-hcp.rb --aws-account ID --ami AMI --acme-email E --openobserve-email E --budget-email E [options]"
      o.on("--aws-account ID", "AWS account ID (12 digits), not an HCP or GitHub one") { |v| opts[:aws_account] = v }
      o.on("--ami AMI", "Amazon Linux 2023 arm64 AMI (runbook step 3)") { |v| opts[:ami] = v }
      o.on("--acme-email EMAIL", "Let's Encrypt contact") { |v| opts[:acme_email] = v }
      o.on("--openobserve-email EMAIL", "OpenObserve sign-in user") { |v| opts[:openobserve_email] = v }
      o.on("--budget-email EMAIL", "AWS budget alert recipient") { |v| opts[:budget_email] = v }
      o.on("--branch BRANCH", "VCS branch the workspaces track (default main)") { |v| opts[:branch] = v }
      o.on("--oauth-token-id ID", "GitHub OAuth connection to use") { |v| opts[:oauth_token_id] = v }
      o.on("--github-app-installation-id ID", "GitHub App installation to use") { |v| opts[:github_app_installation_id] = v }
      o.on("--health-assessments", "turn on drift detection (needs a plan that includes it)") { opts[:health_assessments] = true }
      o.on("--apply", "make the changes") { opts[:apply] = true }
    end.parse!(argv)
    raise Abort, "--aws-account must be 12 digits" unless opts[:aws_account].to_s.match?(/\A\d{12}\z/)
    raise Abort, "--ami must look like ami-0123456789abcdef0" unless opts[:ami].to_s.match?(/\Aami-[0-9a-f]{8,17}\z/)

    %i[acme_email openobserve_email budget_email].each do |key|
      raise Abort, "--#{key.to_s.tr('_', '-')} must be an email address" unless opts[key].to_s.match?(/\A[^@\s]+@[^@\s]+\z/)
    end
    opts
  rescue OptionParser::ParseError => e
    raise Abort, e.message
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    opts = HcpBootstrap.parse(ARGV)
    HcpBootstrap::Bootstrap.new(api: HcpBootstrap::Api.new(HcpBootstrap.load_token), opts: opts).run
  rescue HcpBootstrap::Abort => e
    warn "error: #{e.message}"
    exit 1
  end
end
