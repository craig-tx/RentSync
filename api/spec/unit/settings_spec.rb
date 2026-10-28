# frozen_string_literal: true

require "spec_helper"

# T011: configuration fails fast, naming what is wrong but never showing a value.
RSpec.describe Rentsync::Settings do
  let(:valid) do
    {
      "RENTSYNC_DATABASE_URL" => "postgres://u:p@db:5432/rentsync",
      "RENTSYNC_ENCRYPTION_KEYS" => "k1=#{['K' * 32].pack('m0')}",
      "RENTSYNC_OPERATOR_SEED_PASSWORD" => "seed-password-16+",
      "RENTSYNC_SESSION_SECRET" => "s" * 32,
      "PMS_PUBLIC_URL" => "https://pms.example.test",
      "PMS_API_URL" => "http://mock_pms:4001",
      "APP_PUBLIC_URL" => "https://app.example.test",
      "WEBHOOK_SUBSCRIBER_URL" => "https://app.example.test/webhooks/pms"
    }
  end

  def with_env(env, &)
    described_class.with_source(env, &)
  end

  it "accepts a complete configuration" do
    with_env(valid) { expect { described_class.validate! }.not_to raise_error }
  end

  it "names every missing required variable at once, without values" do
    env = valid.except("RENTSYNC_SESSION_SECRET", "PMS_API_URL", "RENTSYNC_ENCRYPTION_KEYS")
    with_env(env) do
      expect { described_class.validate! }.to raise_error(described_class::Error) { |e|
        expect(e.message).to include("RENTSYNC_SESSION_SECRET", "PMS_API_URL", "RENTSYNC_ENCRYPTION_KEYS")
        valid.each_value { |v| expect(e.message).not_to include(v) }
      }
    end
  end

  it "treats a blank value as missing" do
    with_env(valid.merge("RENTSYNC_OPERATOR_SEED_PASSWORD" => "  ")) do
      expect { described_class.validate! }.to raise_error(described_class::Error, /RENTSYNC_OPERATOR_SEED_PASSWORD/)
    end
  end

  %w[PMS_PUBLIC_URL PMS_API_URL APP_PUBLIC_URL WEBHOOK_SUBSCRIBER_URL].each do |name|
    it "requires #{name} to be an absolute http(s) URL, without echoing it" do
      ["/webhooks/pms", "localhost:4002", "ftp://x.test/", "https://"].each do |bad|
        with_env(valid.merge(name => bad)) do
          expect { described_class.validate! }.to raise_error(described_class::Error) { |e|
            expect(e.message).to include(name)
            expect(e.message).not_to include(bad)
          }
        end
      end
    end
  end

  it "requires a seed password of at least 16 characters and a session secret of at least 32" do
    with_env(valid.merge("RENTSYNC_OPERATOR_SEED_PASSWORD" => "short-password")) do
      expect { described_class.validate! }.to raise_error(described_class::Error, /RENTSYNC_OPERATOR_SEED_PASSWORD.*16/)
    end
    with_env(valid.merge("RENTSYNC_SESSION_SECRET" => "s" * 31)) do
      expect { described_class.validate! }.to raise_error(described_class::Error, /RENTSYNC_SESSION_SECRET.*32/)
    end
  end

  it "rejects malformed encryption keys without showing the key" do
    with_env(valid.merge("RENTSYNC_ENCRYPTION_KEYS" => "k1=not-base64-SECRETISH")) do
      expect { described_class.validate! }.to raise_error(described_class::Error) { |e|
        expect(e.message).to include("RENTSYNC_ENCRYPTION_KEYS")
        expect(e.message).not_to include("SECRETISH")
      }
    end
  end

  it "has the documented defaults" do
    with_env(valid) do
      expect(described_class.reconcile_interval_s).to eq(900)
      expect(described_class.reconcile_overlap_s).to eq(3600)
      expect(described_class.pms_rate_limit_per_minute).to eq(50)
      expect(described_class.redis_url).to eq("redis://localhost:6379/1")
    end
  end

  it "reads overrides as integers and refuses non-integers by name" do
    with_env(valid.merge("RECONCILE_INTERVAL_S" => "60", "PMS_RATE_LIMIT_PER_MINUTE" => "30")) do
      expect(described_class.reconcile_interval_s).to eq(60)
      expect(described_class.pms_rate_limit_per_minute).to eq(30)
    end
    with_env(valid.merge("RECONCILE_OVERLAP_S" => "an hour")) do
      expect { described_class.validate! }.to raise_error(described_class::Error, /RECONCILE_OVERLAP_S/)
    end
  end

  it "uses the test database URL under RACK_ENV=test" do
    with_env(valid.merge("RACK_ENV" => "test", "RENTSYNC_TEST_DATABASE_URL" => "postgres://t/test")) do
      expect(described_class.database_url).to eq("postgres://t/test")
    end
    with_env(valid.merge("RACK_ENV" => "production")) do
      expect(described_class.database_url).to eq("postgres://u:p@db:5432/rentsync")
    end
  end

  it "rejects an invalid DEPLOYMENT_ID" do
    with_env(valid.merge("DEPLOYMENT_ID" => "Prod_US")) do
      expect { described_class.deployment_id }.to raise_error(ArgumentError, /DEPLOYMENT_ID/)
    end
  end
end
