# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rentsync::Metrics::Exposition do
  it "labels target_info with deployment_id next to deployment_environment (constitution VI)" do
    info = described_class.render.lines.find { |l| l.start_with?("target_info{") }
    expect(info).to include(%(deployment_id="#{Rentsync::Settings.deployment_id}"))
    expect(info).to include(%(deployment_environment="#{Rentsync::Settings.deployment_environment}"))
  end

  # Prometheus text format: in label values, a backslash becomes \\, a double quote \" and a
  # newline \n, so one sample stays on one line.
  it "escapes backslashes, quotes and newlines in label values" do
    raw = "a\\b\"c\nd"
    collector = -> { [["rentsync_test_gauge", :gauge, "Escaping.", [[{ "v" => raw }, 1]]]] }
    described_class.collectors << collector
    line = described_class.render.lines.find { |l| l.start_with?("rentsync_test_gauge{") }
    expected_value = 'a\\\\b\\"c\\nd' # single-quoted: a \\ b \" c \n d
    expect(line).to eq(%(rentsync_test_gauge{v="#{expected_value}"} 1\n))
  ensure
    described_class.collectors.delete(collector)
  end
end
