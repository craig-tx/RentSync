# frozen_string_literal: true

require "spec_helper"
require "open3"

# Feature 002 research R10: `bin/setup --deploy` is the non-destructive setup a release runs
# on a deployed host. It must never reseed a database that already has data (FR-030).
RSpec.describe "bin/setup --deploy" do
  let(:scratch_name) { "mock_pms_setup_deploy_spec" }
  let(:scratch_url) { ENV.fetch("TEST_DATABASE_URL").sub(%r{/[^/]+\z}, "/#{scratch_name}") }
  let(:admin_url) { ENV.fetch("TEST_DATABASE_URL").sub(%r{/[^/]+\z}, "/postgres") }
  let(:script) { File.expand_path("../../bin/setup", __dir__) }

  def drop_scratch!
    Sequel.connect(admin_url) { |db| db.run("DROP DATABASE IF EXISTS #{scratch_name} WITH (FORCE)") }
  end

  # No TEST_DATABASE_URL in the child: a deployed host has none.
  def run_deploy
    env = ENV.to_h.merge("RACK_ENV" => "production", "DATABASE_URL" => scratch_url, "TEST_DATABASE_URL" => nil)
    Open3.capture2e(env, "bundle", "exec", "ruby", script, "--deploy", unsetenv_others: false)
  end

  def scratch(&) = Sequel.connect(scratch_url, &)

  before { drop_scratch! }
  after { drop_scratch! }

  it "creates, migrates and seeds an empty database, then never reseeds it" do
    test_db_tables_before = MockPms.db.tables.sort

    output, status = run_deploy
    expect(status).to be_success, output
    expect(output).to include("setup complete (deploy; seeded=true)")
    scratch do |db|
      expect(db[:schema_info].get(:version)).to be_positive
      expect(db[:operators].count).to be_positive
      db[:clients].insert(id: "client_keepme", name: "survives", secret_digest: "x", redirect_uris: Sequel.pg_array(["http://x/cb"]),
                          signing_secret: "s", created_at: Time.now.utc, updated_at: Time.now.utc)
    end

    output, status = run_deploy
    expect(status).to be_success, output
    expect(output).to include("setup complete (deploy; seeded=false)")
    scratch { |db| expect(db[:clients].where(id: "client_keepme").count).to eq(1) }

    expect(MockPms.db.tables.sort).to eq(test_db_tables_before)
  end
end
