# frozen_string_literal: true

require "spec_helper"

# T023: the worker loop beats, runs its jobs, survives job errors, and stops promptly on
# request after the job in hand finishes.
RSpec.describe Rentsync::Worker do
  let(:io) { StringIO.new }

  around do |example|
    original = Rentsync::Logging.io
    Rentsync::Logging.io = io
    example.run
  ensure
    Rentsync::Logging.io = original
  end

  def start(worker) = Thread.new { worker.run }.tap { sleep 0.2 }

  it "writes a heartbeat row under its worker ID" do
    worker = described_class.new(jobs: [], id: "host-a:1", poll_s: 0.05)
    worker.tick
    expect(Rentsync.db[:worker_heartbeats].where(worker_id: "host-a:1").get(:beat_at)).to be_within(5).of(Time.now.utc)
  end

  it "runs every registered job each tick" do
    a = RecordingJob.new
    b = RecordingJob.new
    worker = described_class.new(jobs: [a, b], id: "w", poll_s: 0.01)
    3.times { worker.tick }
    expect([a.runs, b.runs]).to eq([3, 3])
  end

  it "stops within a second of stop! while idle", :committed do
    worker = described_class.new(jobs: [RecordingJob.new], id: "w", poll_s: 30)
    thread = start(worker)
    worker.stop!
    expect(thread.join(1)).to be_truthy
  end

  it "finishes the job in hand before stopping", :committed do
    hold = Queue.new
    job = RecordingJob.new(hold: hold)
    worker = described_class.new(jobs: [job], id: "w", poll_s: 0.01)
    thread = start(worker)
    worker.stop!
    expect(thread.join(0.3)).to be_nil # still inside the job
    hold << :done
    expect(thread.join(1)).to be_truthy
    expect(job.runs).to eq(1)
  end

  it "logs a failing job and keeps going" do
    broken = Object.new
    def broken.run_once = raise(Sequel::DatabaseConnectionError, "db gone")
    ok = RecordingJob.new
    worker = described_class.new(jobs: [broken, ok], id: "w", poll_s: 0.01, error_pause_s: 0)
    2.times { worker.tick }
    expect(ok.runs).to eq(2)
    expect(io.string).to include("job failed", "Sequel::DatabaseConnectionError")
  end

  it "serves cluster metrics and liveness on its own port's app" do
    app = described_class.metrics_app
    metrics = Rack::MockRequest.new(app).get("/metrics")
    expect(metrics.status).to eq(200)
    expect(metrics.body).to include("target_info")
    expect(Rack::MockRequest.new(app).get("/healthz/live").status).to eq(200)
    expect(Rack::MockRequest.new(app).get("/other").status).to eq(404)
  end

  it "has a job registry that later phases add to" do
    expect(described_class.jobs).to be_an(Array)
  end
end
