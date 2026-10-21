# frozen_string_literal: true

# Each test process uses its own key prefix and cleans it up after every example.
MockPms::Redis.prefix = "mock_pms:test:#{Process.pid}:"

module RedisSupport
  module_function

  def clear!
    client = MockPms::Redis.client
    keys = client.scan_each(match: "#{MockPms::Redis.prefix}*").to_a
    client.del(*keys) unless keys.empty?
  end
end

RSpec.configure do |config|
  config.before { MockPms::Metrics.reset! if defined?(MockPms::Metrics) }
  config.after { RedisSupport.clear! }
end
