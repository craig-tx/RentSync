# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Metrics::Exposition do
  it "labels target_info with deployment_id next to deployment_environment (constitution VI)" do
    info = described_class.render.lines.find { |l| l.start_with?("target_info{") }
    expect(info).to include(%(deployment_id="#{MockPms::Settings.deployment_id}"))
    expect(info).to include(%(deployment_environment="#{MockPms::Settings.deployment_environment}"))
  end
end
