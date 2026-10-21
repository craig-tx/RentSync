# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Settings do
  describe ".deployment_id (constitution VI, feature 002 FR-041)" do
    around do |example|
      original = ENV.fetch("DEPLOYMENT_ID", nil)
      example.run
    ensure
      original.nil? ? ENV.delete("DEPLOYMENT_ID") : ENV["DEPLOYMENT_ID"] = original
    end

    it "reads DEPLOYMENT_ID" do
      ENV["DEPLOYMENT_ID"] = "prod-us"
      expect(described_class.deployment_id).to eq("prod-us")
    end

    it "defaults to local-dev when unset" do
      ENV.delete("DEPLOYMENT_ID")
      expect(described_class.deployment_id).to eq("local-dev")
    end

    %w[prod-us dev-staging shared-us pr-42].each do |valid|
      it "accepts #{valid}" do
        ENV["DEPLOYMENT_ID"] = valid
        expect(described_class.deployment_id).to eq(valid)
      end
    end

    ["Prod_US", "a", "-x", "x-", "a#{'b' * 16}"].each do |invalid|
      it "rejects #{invalid.inspect}, naming the variable" do
        ENV["DEPLOYMENT_ID"] = invalid
        expect { described_class.deployment_id }.to raise_error(ArgumentError, /DEPLOYMENT_ID/)
      end
    end
  end
end
