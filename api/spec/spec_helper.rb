# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["RENTSYNC_TEST_DATABASE_URL"] ||= "postgres://postgres:postgres@postgres:5432/rentsync_local_dev_test"
ENV["RENTSYNC_REDIS_URL"] ||= "redis://redis:6379/1"
# Fixed test values for the remaining settings, whatever .env holds, so specs are deterministic.
{
  "RENTSYNC_ENCRYPTION_KEYS" => "test=#{['T' * 32].pack('m0')}",
  "RENTSYNC_OPERATOR_SEED_PASSWORD" => "test-operator-password",
  "RENTSYNC_SESSION_SECRET" => "test-session-secret-0123456789abcdef",
  "MOCK_PMS_ADMIN_TOKEN" => "test-mock-admin-token",
  "PMS_PUBLIC_URL" => "http://pms.test",
  "PMS_API_URL" => "http://pms-api.test",
  "APP_PUBLIC_URL" => "http://app.test",
  "WEBHOOK_SUBSCRIBER_URL" => "http://app.test/webhooks/pms"
}.each { |k, v| ENV[k] = v }

require_relative "../lib/rentsync"
Rentsync.boot!(migrate: true)

require "rack/test"
require "stringio"

# Keep test output readable; specs that inspect logs swap in their own IO.
Rentsync::Logging.io = StringIO.new unless ENV["LOG_TO_STDOUT"]

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "tmp/rspec_status.txt"
  config.include Rack::Test::Methods, type: :request
end
