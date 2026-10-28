# frozen_string_literal: true

require "redis"

module Rentsync
  # Shared Redis connection, key namespacing, and cached Lua scripts (EVALSHA,
  # reloaded on NOSCRIPT). The ::Redis client is thread-safe and fork-aware.
  module Redis
    class << self
      attr_writer :prefix

      def prefix = @prefix ||= "rentsync:"

      def client
        @client ||= ::Redis.new(url: Settings.redis_url, reconnect_attempts: 1, timeout: 2)
      end

      def key(*parts) = "#{prefix}#{parts.join(':')}"

      def ping?
        client.ping == "PONG"
      rescue ::Redis::BaseError, SystemCallError
        false
      end

      def load_script(name, path)
        scripts[name] = { source: File.read(path), sha: nil }
      end

      def evalsha(name, keys:, argv:)
        script = scripts.fetch(name)
        script[:sha] ||= client.script(:load, script[:source])
        client.evalsha(script[:sha], keys: keys, argv: argv)
      rescue ::Redis::CommandError => e
        raise unless e.message.start_with?("NOSCRIPT")

        script[:sha] = client.script(:load, script[:source])
        client.evalsha(script[:sha], keys: keys, argv: argv)
      end

      private

      def scripts = @scripts ||= {}
    end
  end
end
