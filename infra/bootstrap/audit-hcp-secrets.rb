#!/usr/bin/env ruby
# frozen_string_literal: true

# Runbook §Checks, SC-004 and FR-024 (feature 002): no secret value in HCP Terraform state or run
# logs. Reads every state version and every run's plan and apply logs of the three workspaces,
# and reports where a secret appears, by name only. It changes nothing in HCP Terraform:
#
#   ruby infra/bootstrap/audit-hcp-secrets.rb [--aws-profile NAME] [--no-values]
#
# Read-only by construction: the HTTP transport below takes a URL and headers and always sends a
# GET; there is no other method in this file (a test checks this). Nothing is written to disk:
# state and logs are read into memory and dropped.
#
# Two kinds of check:
#   - By value: each secret's current value is read from SSM Parameter Store with the AWS CLI
#     (--aws-profile, default rentsync) and searched for in state, in user data (decoded) and in
#     logs. A secret that profile cannot decrypt is reported and checked by attribute only. The
#     rentsync operator role decrypts only the admin tokens. Rotated-away values are not known.
#   - By attribute: a SecureString parameter or a managed random_password with its value in state
#     fails. Other attributes or outputs marked sensitive that hold a value, and log lines that
#     assign a literal to a password, secret or token key, are listed as notes to look at.
#
# The token comes from `terraform login` (as for bootstrap-hcp.rb) and is sent only to HCP
# Terraform's own hosts. No value, of a secret or of the token, is ever printed.
# Exit status: 0 when nothing was found, 1 when something was, 2 on an error.
require "json"
require "net/http"
require "open3"
require "optparse"
require "uri"
require "zlib"
require_relative "bootstrap-hcp"

module HcpSecretAudit
  Abort = HcpBootstrap::Abort
  WORKSPACES = HcpBootstrap::WORKSPACES.map { |ws| ws[:name] }.freeze
  # SecureString parameters (infra/terraform/*/secrets.tf), by deployment.
  SECRETS = {
    "dev-staging" => %w[admin_token postgres_password],
    "prod-us" => %w[admin_token postgres_password],
    "shared-us" => %w[openobserve/root_password openobserve/ingest/password openobserve/db_password]
  }.freeze
  TOKEN_HOSTS = %w[app.terraform.io archivist.terraform.io].freeze
  MIN_SECRET_LENGTH = 8 # shorter values would match by chance
  SECRET_KEY = /(password|secret|token|private_key)/i

  # Sends a GET and returns [status, headers, body]. The only network code in this file.
  NET_GET = lambda do |uri, headers|
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    [res.code.to_i, res.to_hash.transform_values(&:first), res.body.to_s]
  end

  class Reader
    BASE = "https://app.terraform.io/api/v2"

    def initialize(token, transport: NET_GET, pause: ->(s) { sleep s })
      @token = token
      @transport = transport
      @pause = pause
    end

    def json(path)
      body = fetch(path.start_with?("https://") ? path : BASE + path, api: true)
      body && JSON.parse(body)
    end

    # Every item of a list endpoint, following pagination, with the included records by id.
    def list(path)
      items = []
      included = {}
      url = path
      while url
        page = json(url) or break
        items.concat(page["data"])
        (page["included"] || []).each { |rec| included[rec["id"]] = rec }
        url = page.dig("links", "next")
      end
      [items, included]
    end

    def download(url) = fetch(url, api: false)

    private

    def fetch(url, api:, redirects: 3, waits: 5)
      uri = URI(url)
      headers = {}
      headers["Authorization"] = "Bearer #{@token}" if uri.scheme == "https" && TOKEN_HOSTS.include?(uri.host)
      headers["Content-Type"] = "application/vnd.api+json" if api
      status, res_headers, body = @transport.call(uri, headers)
      case status
      when 200..299 then body
      when 404 then nil
      when 301, 302, 303, 307, 308
        raise Abort, "too many redirects from #{uri.host}#{uri.path}" if redirects.zero?

        fetch(URI.join(url, res_headers["location"]).to_s, api: api, redirects: redirects - 1, waits: waits)
      when 429
        raise Abort, "HCP Terraform kept rate-limiting #{uri.path}" if waits.zero?

        @pause.call([res_headers["retry-after"].to_f, 1].max)
        fetch(url, api: api, redirects: redirects, waits: waits - 1)
      else
        raise Abort, "GET #{uri.host}#{uri.path}: HTTP #{status}"
      end
    end
  end

  # Reads each secret's current value from SSM. Returns { label => value or nil } and the reasons
  # for the nils. Values never leave this process.
  def self.secret_values(profile:, region:, run: ->(*cmd) { Open3.capture3({ "MSYS_NO_PATHCONV" => "1" }, *cmd) })
    values = {}
    missing = {}
    SECRETS.each do |deployment, names|
      names.each do |name|
        label = "#{deployment} #{name}"
        out, err, status = run.call("aws", "ssm", "get-parameter", "--name", "/rentsync/#{deployment}/#{name}",
                                    "--with-decryption", "--query", "Parameter.Value", "--output", "text",
                                    "--profile", profile, "--region", region)
        value = out.to_s.chomp
        if status.success? && value.length >= MIN_SECRET_LENGTH
          values[label] = value
        else
          missing[label] = status.success? ? "too short to search for" : err.to_s[/AccessDenied|ParameterNotFound|ExpiredToken|\w+Exception/] || "could not be read"
        end
      end
    end
    [values, missing]
  end

  # Strings to search: the text itself, plus any base64 (and gzipped base64) blob decoded, so user
  # data is searched as the host sees it.
  def self.decoded_views(text)
    text.scan(%r{[A-Za-z0-9+/]{40,}={0,2}}).filter_map do |blob|
      raw = blob.unpack1("m")
      raw = Zlib.gunzip(raw) if raw.start_with?("\x1f\x8b".b)
      raw.force_encoding(Encoding::UTF_8)
    rescue Zlib::Error, ArgumentError
      nil
    end
  end

  def self.value_hits(text, values)
    views = [text] + decoded_views(text)
    values.keys.select { |label| views.any? { |v| v.b.include?(values[label].b) } }
  end

  def self.present?(value) = !(value.nil? || value == "" || value == [] || value == {})

  def self.step_key(step)
    key = step.is_a?(Hash) ? step["value"] : step
    key.is_a?(Hash) ? key["value"] : key # an index step: { "type": "index", "value": { "value": 0, ... } }
  end

  def self.dig_path(attrs, path)
    path.reduce(attrs) do |node, step|
      key = step_key(step)
      case node
      when Hash then node[key.to_s]
      when Array then key.is_a?(Integer) ? node[key] : nil
      end
    end
  end

  # Returns [failures, notes] for one state file.
  def self.scan_state(text, values)
    failures = value_hits(text, values).map { |label| "holds the value of #{label}" }
    notes = []
    state = JSON.parse(text)
    (state["resources"] || []).each do |res|
      next unless res["mode"] == "managed"

      (res["instances"] || []).each do |inst|
        name = [res["module"], "#{res['type']}.#{res['name']}"].compact.join(".")
        name += "[#{inst['index_key'].inspect}]" if inst.key?("index_key")
        attrs = inst["attributes"] || {}
        if res["type"] == "aws_ssm_parameter" && attrs["type"] == "SecureString"
          %w[value value_wo insecure_value].each do |key|
            failures << "#{name}: SecureString attribute #{key} is set" if present?(attrs[key])
          end
        elsif %w[random_password random_string].include?(res["type"]) && present?(attrs["result"])
          failures << "#{name}: result is set (use an ephemeral resource)"
        end
        # The provider marks every parameter's value sensitive: SecureString is checked above, and
        # a String parameter is not a secret by design.
        next if res["type"] == "aws_ssm_parameter"

        (inst["sensitive_attributes"] || []).each do |path|
          steps = path.is_a?(Hash) ? [path] : Array(path) # a path is a list of { "type", "value" } steps
          next unless present?(dig_path(attrs, steps))

          notes << "#{name}: attribute #{steps.map { |s| step_key(s) }.join('.')} is marked sensitive and holds a value"
        end
      end
    end
    (state["outputs"] || {}).each do |key, out|
      notes << "output #{key} is marked sensitive and holds a value" if out["sensitive"] && present?(out["value"])
    end
    [failures, notes]
  rescue JSON::ParserError
    [failures || [], ["not JSON, so searched by value only"]]
  end

  # Returns [failures, notes] for one log; each names a line number.
  def self.scan_log(text, values)
    failures = []
    notes = []
    text.each_line.with_index(1) do |line, n|
      line = line.gsub(/\e\[[0-9;]*m/, "")
      value_hits(line, values).each { |label| failures << "line #{n} holds the value of #{label}" }
      line.scan(/"?([\w.\/-]+)"?\s*[=:]\s*"([^"]*)"/).each do |key, literal|
        next unless key.match?(SECRET_KEY)
        next if literal.empty? || literal.start_with?("(") || literal.start_with?("/rentsync/")

        notes << "line #{n}: #{key} is assigned a literal"
      end
    end
    [failures, notes]
  end

  class Audit
    def initialize(reader:, org:, values:, missing:, out: $stdout)
      @reader = reader
      @org = org
      @values = values
      @missing = missing
      @out = out
      @failures = 0
      @notes = 0
    end

    # Prints the report; true when no failure was found.
    def run
      @reader.json("/organizations/#{@org}") or raise Abort, "organization #{@org} not found, or the token can't see it"
      @out.puts "Searching by value for: #{@values.keys.join(', ')}" unless @values.empty?
      @missing.each { |label, why| @out.puts "Checked by attribute only (#{why}): #{label}" }
      WORKSPACES.each { |name| audit_workspace(name) }
      @out.puts ""
      if @failures.zero?
        @out.puts "PASS: no secret found in HCP Terraform state or run logs (#{@notes} note(s) to look at)."
      else
        @out.puts "FAIL: #{@failures} finding(s). Values are not shown; open the state version or run named above."
      end
      @failures.zero?
    end

    private

    def audit_workspace(name)
      ws = @reader.json("/organizations/#{@org}/workspaces/#{name}") or return @out.puts("#{name}: not found, skipped")
      @ws_notes = {}
      states, = @reader.list("/state-versions?filter%5Bworkspace%5D%5Bname%5D=#{name}" \
                             "&filter%5Borganization%5D%5Bname%5D=#{@org}&page%5Bsize%5D=100")
      states.each do |sv|
        url = sv.dig("attributes", "hosted-state-download-url") or next
        text = @reader.download(url) or next
        report("#{name} state #{sv['id']} (serial #{sv.dig('attributes', 'serial')})", *HcpSecretAudit.scan_state(text, @values))
      end
      runs, included = @reader.list("/workspaces/#{ws['data']['id']}/runs?include=plan%2Capply&page%5Bsize%5D=100")
      logs = 0
      runs.each do |run|
        %w[plan apply].each do |part|
          id = run.dig("relationships", part, "data", "id") or next
          url = included.dig(id, "attributes", "log-read-url") or next
          text = @reader.download(url) or next
          logs += 1
          report("#{name} run #{run['id']} #{part} log", *HcpSecretAudit.scan_log(text, @values))
        end
      end
      flush_notes
      @out.puts "#{name}: #{states.size} state version(s), #{runs.size} run(s), #{logs} log(s) checked"
    end

    # Failures print at once. A note usually repeats in every state version or run, so each is
    # printed once per workspace, with where it was first seen and how often.
    def report(where, failures, notes)
      failures.each { |f| @out.puts "  FAIL  #{where}: #{f}" }
      @failures += failures.size
      notes.each { |n| (@ws_notes[n] ||= [where, 0])[1] += 1 }
    end

    def flush_notes
      @ws_notes.each do |note, (where, count)|
        @out.puts "  note  #{where}: #{note}#{count > 1 ? " (in #{count} places)" : ''}"
      end
      @notes += @ws_notes.size
    end
  end

  def self.parse(argv)
    opts = { aws_profile: "rentsync", values: true }
    OptionParser.new do |o|
      o.banner = "usage: ruby infra/bootstrap/audit-hcp-secrets.rb [--aws-profile NAME] [--no-values]"
      o.on("--aws-profile NAME", "AWS CLI profile that reads the secrets from SSM (default rentsync)") { |v| opts[:aws_profile] = v }
      o.on("--no-values", "skip SSM; check by attribute only") { opts[:values] = false }
    end.parse!(argv)
    raise Abort, "unexpected argument #{argv.first}" unless argv.empty?

    opts
  rescue OptionParser::ParseError => e
    raise Abort, e.message
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    opts = HcpSecretAudit.parse(ARGV)
    settings = HcpBootstrap.load_settings
    org = settings[:hcp_org] or raise HcpSecretAudit::Abort, "no RENTSYNC_HCP_ORG in the settings; run bootstrap-init.sh"
    values, missing =
      if opts[:values]
        HcpSecretAudit.secret_values(profile: opts[:aws_profile], region: settings[:region] || "us-east-1")
      else
        [{}, HcpSecretAudit::SECRETS.flat_map { |d, names| names.map { |n| ["#{d} #{n}", "--no-values"] } }.to_h]
      end
    reader = HcpSecretAudit::Reader.new(HcpBootstrap.load_token)
    ok = HcpSecretAudit::Audit.new(reader: reader, org: org, values: values, missing: missing).run
    exit(ok ? 0 : 1)
  rescue HcpSecretAudit::Abort => e
    warn "error: #{e.message}"
    exit 2
  end
end
