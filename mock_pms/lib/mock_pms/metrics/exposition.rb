# frozen_string_literal: true

module MockPms
  module Metrics
    # Renders cluster-wide totals from Redis (plus any database-backed collectors) as
    # Prometheus text format 0.0.4. Every instance renders the same values.
    module Exposition
      CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

      class << self
        # Each collector returns [[name, type, help, [[labels_hash, value], ...]], ...].
        def collectors = @collectors ||= []

        def render
          lines = target_info
          FAMILIES.each do |family, (type, help)|
            lines.concat(type == :histogram ? histogram(family, help) : counter(family, help))
          end
          collectors.each do |c|
            c.call.each do |name, type, help, samples|
              lines.concat(family_lines(name, type, help, samples))
            end
          end
          "#{lines.join("\n")}\n"
        end

        private

        def target_info
          labels = {
            "service_name" => "mock_pms-web",
            "service_version" => Settings.service_version,
            "deployment_environment" => Settings.deployment_environment,
            "deployment_id" => Settings.deployment_id
          }
          ["# HELP target_info Target metadata.", "# TYPE target_info gauge", "target_info#{fmt(labels)} 1"]
        end

        def hash(family) = MockPms::Redis.client.hgetall(MockPms::Redis.key("metrics", family))

        def counter(family, help)
          samples = hash(family).map { |labels, v| [Metrics.parse_labels(labels), v.to_i] }
          family_lines(family, :counter, help, samples)
        end

        def histogram(family, help)
          counts = hash("#{family}_count")
          return [] if counts.empty?

          sums = hash("#{family}_sum")
          buckets = hash("#{family}_bucket")
          lines = ["# HELP #{family} #{help}", "# TYPE #{family} histogram"]
          counts.sort.each do |labels, count|
            base = Metrics.parse_labels(labels)
            cumulative = 0
            BUCKETS.each do |le|
              cumulative += buckets.fetch(labels.empty? ? "le=#{le}" : "#{labels}|le=#{le}", 0).to_i
              lines << "#{family}_bucket#{fmt(base.merge('le' => le.to_s))} #{cumulative}"
            end
            lines << "#{family}_bucket#{fmt(base.merge('le' => '+Inf'))} #{count.to_i}"
            lines << "#{family}_sum#{fmt(base)} #{sums.fetch(labels, '0').to_f}"
            lines << "#{family}_count#{fmt(base)} #{count.to_i}"
          end
          lines
        end

        def family_lines(name, type, help, samples)
          return [] if samples.empty?

          ["# HELP #{name} #{help}", "# TYPE #{name} #{type}"] +
            samples.sort_by { |labels, _| labels.to_a.sort }.map { |labels, v| "#{name}#{fmt(labels)} #{v}" }
        end

        def fmt(labels)
          return "" if labels.empty?

          inner = labels.sort.map { |k, v| %(#{k}="#{v.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}") }
          "{#{inner.join(',')}}"
        end
      end
    end
  end
end
