# frozen_string_literal: true

require "spec_helper"

# T049, research R2 and FR-020: due connections are claimed from Postgres under a lease, so any
# number of workers is safe; "Reconcile now" makes a connection due at once.
RSpec.describe Rentsync::Reconciliation::Scheduler do
  let(:now) { Time.utc(2026, 10, 31, 14) }
  let(:pms_client) do
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: "mock_pms", base_url: "http://pms.test", client_id: "client_A", registered_at: Time.now.utc },
      client_secret: "CS-A", signing_secret: "SS-A"
    )
  end
  let(:ran) { Queue.new }
  let(:runner) { ->(connection, trigger) { ran << [connection.id, trigger] } }

  def connection(n, status: "active", due_at: now - 1, **extra)
    operator = Rentsync::Operator.create(email: "op#{n}@example.test", name: "Op #{n}", password_digest: "x")
    Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: pms_client.id, pms_operator_id: "op_#{n}",
                                   pms_operator_name: "PMS #{n}", status: status, next_reconcile_at: due_at, **extra)
  end

  def scheduler = described_class.new(runner: runner)
  def ran_ids = Array.new(ran.size) { ran.pop }.map(&:first)

  before { freeze_time(now) }

  describe "claiming" do
    it "claims a due connection, leases it, and runs it once" do
      con = connection(1)
      expect(scheduler.run_once).to eq(1)
      expect(ran_ids).to eq([con.id])
      expect(con.refresh.reconcile_lease_until).to eq(now + described_class::LEASE_S)
    end

    it "returns 0 when nothing is due" do
      connection(1, due_at: now + 60)
      expect(scheduler.run_once).to eq(0)
      expect(ran.size).to eq(0)
    end

    it "claims only active and renewal_failing connections" do
      live = [connection(1), connection(2, status: "renewal_failing")]
      connection(3, status: "needs_reauth")
      connection(4, status: "disconnected")
      4.times { scheduler.run_once }
      expect(ran_ids.sort).to eq(live.map(&:id).sort)
    end

    it "skips a held lease and reclaims an expired one" do
      con = connection(1, reconcile_lease_until: now + 60)
      expect(scheduler.run_once).to eq(0)
      advance(61)
      expect(scheduler.run_once).to eq(1)
      expect(ran_ids).to eq([con.id])
    end

    it "names the trigger: initial without a watermark, manual when requested, otherwise schedule" do
      first = connection(1)
      requested = connection(2, reconcile_watermark: now - 900, reconcile_requested_at: now - 5)
      scheduled = connection(3, reconcile_watermark: now - 900)
      3.times { scheduler.run_once }
      triggers = Array.new(ran.size) { ran.pop }.to_h
      expect(triggers).to eq(first.id => "initial", requested.id => "manual", scheduled.id => "schedule")
    end

    it "is one of the worker's jobs" do
      expect(Rentsync::Worker.jobs.map(&:class)).to include(described_class)
    end
  end

  describe "two schedulers at once", :committed do
    it "never claim the same connection" do
      ids = Array.new(3) { |i| connection(i + 1).id }
      gate = Queue.new
      slow = lambda do |con, trigger|
        gate.pop
        runner.call(con, trigger)
      end
      threads = Array.new(6) { Thread.new { described_class.new(runner: slow).run_once } }
      sleep 0.3
      6.times { gate << :go }
      expect(threads.map(&:value).sum).to eq(3)
      expect(ran_ids.sort).to eq(ids.sort)
    end
  end

  describe "POST /connections/:id/reconcile", type: :request do
    def app = Rentsync::App.build
    def base = "https://app.test"

    let(:password) { "operator-password-1" }
    let!(:ann) { connection(1, due_at: now + 900, reconcile_watermark: now - 60) }
    let!(:bo) { connection(2, due_at: now + 900) }

    before do
      Rentsync::Operator.where(id: ann.operator_id).update(password_digest: Rentsync::Auth::Passwords.digest(password))
      post "#{base}/sign-in", email: "op1@example.test", password: password
    end

    def csrf
      get "#{base}/connections"
      last_response.body[/name="csrf_token" value="([^"]+)"/, 1]
    end

    it "makes the connection due now and marks it requested" do
      post "#{base}/connections/#{ann.public_id}/reconcile", csrf_token: csrf
      expect(last_response.status).to eq(303)
      expect(ann.refresh).to have_attributes(next_reconcile_at: now, reconcile_requested_at: now)
    end

    it "offers Reconcile now on the connections page" do
      get "#{base}/connections"
      expect(last_response.body).to include("/connections/#{ann.public_id}/reconcile")
    end

    it "answers 409 for a connection that is not reconciled" do
      %w[needs_reauth disconnected].each do |status|
        ann.this.update(status: status)
        post "#{base}/connections/#{ann.public_id}/reconcile", csrf_token: csrf
        expect(last_response.status).to eq(409), status
      end
      expect(ann.refresh.reconcile_requested_at).to be_nil
    end

    it "requires the CSRF token, and 404s another operator's connection" do
      post "#{base}/connections/#{ann.public_id}/reconcile"
      expect(last_response.status).to eq(403)
      post "#{base}/connections/#{bo.public_id}/reconcile", csrf_token: csrf
      expect(last_response.status).to eq(404)
      expect(bo.refresh.reconcile_requested_at).to be_nil
    end
  end
end
