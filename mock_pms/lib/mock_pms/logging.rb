# frozen_string_literal: true

require "json"

module MockPms
  # One JSON object per line on stdout, with OpenTelemetry semantic-convention field
  # names so the Collector maps them without renaming (research R12, R16).
  # Code logs only through Loggable, which records the calling method automatically.
  module Logging
    LEVELS = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
    REDACTED = "[REDACTED]"
    SECRET_KEY = /token|secret|password|authorization/i
    PII_KEYS = %w[name first_name last_name email phone amount_cents].to_set.freeze

    class << self
      attr_writer :io, :service_name

      def io = @io ||= $stdout
      def service_name = @service_name || ENV.fetch("SERVICE_NAME", "mock_pms-web")

      def min_level = LEVELS.fetch(ENV.fetch("LOG_LEVEL", "INFO").upcase, 1)

      def mutex = @mutex ||= Mutex.new

      def emit(severity, body, function:, location:, fields:)
        return if LEVELS.fetch(severity) < min_level

        line = base_fields(severity, body, function, location).merge(redact(fields))
        json = JSON.generate(line)
        mutex.synchronize { io.write("#{json}\n") }
      end

      def redact(value)
        case value
        when Hash
          value.to_h { |k, v| [k, redact_key?(k) ? REDACTED : redact(v)] }
        when Array
          value.map { |v| redact(v) }
        else
          value
        end
      end

      private

      def redact_key?(key)
        name = key.to_s
        SECRET_KEY.match?(name) || PII_KEYS.include?(name)
      end

      def base_fields(severity, body, function, location)
        {
          "timestamp" => Time.now.utc.iso8601(3),
          "severity_text" => severity,
          "body" => body,
          "service.name" => service_name,
          "service.version" => Settings.service_version,
          "deployment.environment" => Settings.deployment_environment,
          "service.instance.id" => Settings.service_instance_id,
          "code.function.name" => function,
          "code.file.path" => location&.path,
          "code.line.number" => location&.lineno,
          "correlation_id" => Thread.current[:correlation_id]
        }
      end
    end

    # Bound to the object that called `log`; records that object's class and the
    # calling method as code.function.name.
    class Proxy
      def initialize(receiver, function: nil)
        @receiver = receiver
        @function = function
      end

      LEVELS.each_key do |severity|
        define_method(severity.downcase) do |body, **fields|
          location = caller_locations(1, 1).first
          Logging.emit(severity, body, function: @function || function_name(location), location: location,
                                       fields: fields)
        end
      end

      private

      def function_name(location)
        method = location&.base_label
        if @receiver.is_a?(Module)
          "#{@receiver.name}.#{method}"
        else
          "#{@receiver.class.name}##{method}"
        end
      end
    end

    module Loggable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def log = Proxy.new(self)
      end

      def log = Proxy.new(self)
    end

    # For lines that describe something other than the calling method, such as the
    # access log, which reports the endpoint or middleware that answered.
    def self.for_function(function) = Proxy.new(nil, function: function)
  end
end
