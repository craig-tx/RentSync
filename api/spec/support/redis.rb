# frozen_string_literal: true

# Each test process uses its own key prefix and cleans it up after every example.
Rentsync::Redis.prefix = "rentsync:test:#{Process.pid}:"

module RedisSupport
  module_function

  def clear!
    client = Rentsync::Redis.client
    keys = client.scan_each(match: "#{Rentsync::Redis.prefix}*").to_a
    client.del(*keys) unless keys.empty?
  end
end

RSpec.configure do |config|
  config.before { Rentsync::Metrics.reset! if defined?(Rentsync::Metrics) }
  config.after { RedisSupport.clear! }
end
