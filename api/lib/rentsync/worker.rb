# frozen_string_literal: true

module Rentsync
  # The background process (bin/worker). Each tick it writes a heartbeat at most every 5 s and
  # runs every registered job once; it sleeps when no job did any work. stop! (SIGTERM) ends
  # the loop after the job in hand. Work is claimed from Postgres by the jobs themselves
  # (research R2), so any number of workers is safe (Constitution X).
  class Worker
    include Logging::Loggable

    HEARTBEAT_EVERY_S = 5
    SLICE_S = 0.1

    # Jobs respond to run_once and return how many items they handled. Later phases register
    # theirs here (reconciliation, purge).
    def self.jobs = @jobs ||= []

    # /metrics (cluster-wide totals, as the API renders them) and /healthz/live, on port 4003.
    def self.metrics_app
      lambda do |env|
        case env["PATH_INFO"]
        when "/metrics" then [200, { "content-type" => Metrics::Exposition::CONTENT_TYPE }, [Metrics::Exposition.render]]
        when "/healthz/live" then [200, { "content-type" => "application/json" }, ['{"status":"ok"}']]
        else [404, { "content-type" => "application/json" }, ['{"error":{"code":"not_found"}}']]
        end
      end
    end

    def initialize(jobs: self.class.jobs, id: "#{Settings.service_instance_id}:#{Process.pid}", poll_s: 1,
                   error_pause_s: 2)
      @jobs = jobs
      @id = id
      @poll_s = poll_s
      @error_pause_s = error_pause_s
      @stopping = false
      @last_beat = nil
    end

    def stop!
      @stopping = true
    end

    def run
      log.info("worker started", worker_id: @id, jobs: @jobs.map { |j| j.class.name })
      until @stopping
        idle = tick.zero?
        pause(@poll_s) if idle
      end
      log.info("worker stopped", worker_id: @id)
    end

    # One pass: heartbeat if due, then each job once. Returns the work done.
    def tick
      heartbeat! if @last_beat.nil? || Clock.now - @last_beat >= HEARTBEAT_EVERY_S
      @jobs.sum { |job| run_job(job) }
    end

    private

    def run_job(job)
      job.run_once.to_i
    rescue StandardError => e
      log.error("job failed", job: job.class.name, error: e.class.name)
      pause(@error_pause_s)
      0
    end

    def heartbeat!
      now = Clock.now
      Rentsync.db[:worker_heartbeats]
              .insert_conflict(target: :worker_id, update: { beat_at: Sequel[:excluded][:beat_at] })
              .insert(worker_id: @id, beat_at: now)
      @last_beat = now
    rescue Sequel::Error => e
      log.error("heartbeat failed", error: e.class.name)
    end

    # Sleeps in short slices so stop! takes effect within SLICE_S.
    def pause(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep SLICE_S while !@stopping && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    end
  end
end
