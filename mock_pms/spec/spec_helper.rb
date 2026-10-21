# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["ADMIN_TOKEN"] ||= "test-admin-token"
ENV["TEST_DATABASE_URL"] ||= "postgres://postgres:postgres@postgres:5432/mock_pms_test"
ENV["REDIS_URL"] ||= "redis://redis:6379/0"

require_relative "../lib/mock_pms"
MockPms.boot!(migrate: true)

require "rack/test"
require "stringio"

# Keep test output readable; specs that inspect logs swap in their own IO.
MockPms::Logging.io = StringIO.new unless ENV["LOG_TO_STDOUT"]

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
