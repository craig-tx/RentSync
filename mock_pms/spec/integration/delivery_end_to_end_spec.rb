# frozen_string_literal: true

require "spec_helper"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "socket"

# Real HTTP: a throwaway receiver on Puma, the real Net::HTTP transport, and the
# worker loop. Committed data, because the worker and receiver use their own threads.
RSpec.describe "webhook delivery end to end", :committed do
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1].tap { server.close }
  end

  def start_receiver(app)
    port = free_port
    config = Puma::Configuration.new do |c|
      c.bind "tcp://127.0.0.1:#{port}"
      c.app app
      c.threads 1, 4
      c.workers 0
      c.log_requests false
      c.quiet
    end
    launcher = Puma::Launcher.new(config, log_writer: Puma::LogWriter.null)
    thread = Thread.new { launcher.run }
    sleep 0.05 until port_open?(port)
    [port, launcher, thread]
  end

  def port_open?(port)
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue Errno::ECONNREFUSED
    false
  end

  def drain(queue)
    items = []
    items << queue.pop until queue.empty?
    items
  end

  let(:schedule) { MockPms::Delivery::RetrySchedule.new(base: 0.05, max_attempts: 8, jitter: -> { 0.0 }) }

  def run_worker_until_idle(worker, timeout: 10)
    deadline = Time.now + timeout
    loop do
      worker.run_once
      break if MockPms::Delivery.exclude(status: %w[succeeded exhausted]).empty? || Time.now > deadline

      sleep 0.05
    end
  end

  def setup_client(port)
    op = Factory.operator
    Factory.lease(op)
    client = Factory.client(subscriber_url: "http://127.0.0.1:#{port}/webhooks").first
    Factory.tokens(client, op)
    client
  end

  it "delivers verifiable, ordered, correlated webhooks, retrying failures with the same event id", :slow do
    # Both deliveries in the first batch fail twice (4 failures), then succeed.
    receiver = RecordingReceiver.new(fail_first: 4)
    port, launcher, thread = start_receiver(receiver)
    client = setup_client(port)
    result = MockPms::Scenarios::TenantMoveOut.run!
    worker = MockPms::Delivery::Worker.new(schedule: schedule, worker_id: "e2e")
    run_worker_until_idle(worker)

    requests = drain(receiver.requests)
    successes = requests.last(2)
    types = successes.map { |r| JSON.parse(r[:body])["type"] }
    expect(types).to eq(%w[lease.updated tenant.moved_out])
    successes.each do |r|
      expect(MockPms::Delivery::Signer.verify(header: r[:headers]["PMS_SIGNATURE"], secret: client.signing_secret,
                                              body: r[:body])).to be(true)
      expect(r[:headers]["X_CORRELATION_ID"]).to eq(result[:run_id])
    end
    first_event = requests.first[:headers]["PMS_EVENT_ID"]
    retried = requests.select { |r| r[:headers]["PMS_EVENT_ID"] == first_event }
    expect(retried.map { |r| r[:headers]["PMS_DELIVERY_ATTEMPT"] }).to eq(%w[1 2 3])
    delivery = MockPms::Delivery.first(event_seq: MockPms::Event.first(id: first_event).seq)
    expect(MockPms::DeliveryAttempt.where(delivery_seq: delivery.seq).count).to eq(3)
  ensure
    launcher&.stop
    thread&.join(5)
  end

  it "delivers within 5 s of the business change with chaos off (SC-003)", :slow do
    receiver = RecordingReceiver.new
    port, launcher, thread = start_receiver(receiver)
    setup_client(port)
    MockPms::Scenarios::TenantMoveOut.run!
    worker = MockPms::Delivery::Worker.new(schedule: schedule, worker_id: "e2e-timing")
    run_worker_until_idle(worker)
    requests = drain(receiver.requests)
    expect(requests.size).to eq(2)
    requests.each do |r|
      event = MockPms::Event.first(id: r[:headers]["PMS_EVENT_ID"])
      expect(r[:at] - event.created_at).to be < 5
    end
  ensure
    launcher&.stop
    thread&.join(5)
  end
end
