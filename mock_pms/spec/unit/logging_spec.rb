# frozen_string_literal: true

require "spec_helper"

class LoggingDummy
  include MockPms::Logging::Loggable

  def work
    log.info("from instance", answer: 42)
  end

  def work_in_block
    [1].each { log.info("from block") }
  end

  def self.build
    log.info("from class method")
  end

  def leak
    log.info("secrets", access_token: "S3CR3T-TOK", client_secret: "S3CR3T-CS", password: "S3CR3T-PW",
                        nested: { email: "ann@example.test", first_name: "Annabelle", amount_cents: 98_765 },
                        list: [{ phone: "555-0199" }], Authorization: "Bearer S3CR3T-AUTH", safe: "ok")
  end
end

RSpec.describe MockPms::Logging do
  let(:io) { StringIO.new }

  around do |example|
    original = described_class.io
    described_class.io = io
    example.run
  ensure
    described_class.io = original
  end

  def lines
    io.string.lines.map { |l| JSON.parse(l) }
  end

  it "writes one JSON object per line with the OTel-named fields" do
    Thread.current[:correlation_id] = "corr-1"
    LoggingDummy.new.work
    line = lines.last
    expect(line.keys).to include(
      "timestamp", "severity_text", "body", "service.name", "service.version",
      "deployment.environment", "service.instance.id", "code.function.name",
      "code.file.path", "code.line.number", "correlation_id"
    )
    expect(line["timestamp"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\z/)
    expect(line["severity_text"]).to eq("INFO")
    expect(line["body"]).to eq("from instance")
    expect(line["answer"]).to eq(42)
    expect(line["correlation_id"]).to eq("corr-1")
    expect(line["code.line.number"]).to be_a(Integer)
  ensure
    Thread.current[:correlation_id] = nil
  end

  it "names an instance method Class#method" do
    LoggingDummy.new.work
    expect(lines.last["code.function.name"]).to eq("LoggingDummy#work")
  end

  it "names a class method Class.method" do
    LoggingDummy.build
    expect(lines.last["code.function.name"]).to eq("LoggingDummy.build")
  end

  it "names a block by its enclosing method" do
    LoggingDummy.new.work_in_block
    expect(lines.last["code.function.name"]).to eq("LoggingDummy#work_in_block")
  end

  it "redacts secrets and personal data before writing, including nested values" do
    LoggingDummy.new.leak
    raw = io.string
    %w[S3CR3T-TOK S3CR3T-CS S3CR3T-PW ann@example.test Annabelle 98765 555-0199 S3CR3T-AUTH].each do |secret|
      expect(raw).not_to include(secret)
    end
    line = lines.last
    expect(line["access_token"]).to eq("[REDACTED]")
    expect(line["client_secret"]).to eq("[REDACTED]")
    expect(line["password"]).to eq("[REDACTED]")
    expect(line["Authorization"]).to eq("[REDACTED]")
    expect(line["nested"]).to eq("email" => "[REDACTED]", "first_name" => "[REDACTED]", "amount_cents" => "[REDACTED]")
    expect(line["list"]).to eq([{ "phone" => "[REDACTED]" }])
    expect(line["safe"]).to eq("ok")
  end
end
