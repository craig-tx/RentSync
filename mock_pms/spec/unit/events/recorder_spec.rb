# frozen_string_literal: true

require "spec_helper"

RSpec.describe MockPms::Events::Recorder do
  let(:op) { Factory.operator }
  let(:other_op) { Factory.operator }

  def subscribed_client(operator, url: "http://receiver.test/webhooks")
    client = Factory.client(subscriber_url: url).first
    Factory.tokens(client, operator)
    client
  end

  def record!(operator = op)
    described_class.record!(type: "payment.created", operator_seq: operator.seq, payload: { "id" => "pay_X" },
                            occurred_at: Time.utc(2026, 10, 1, 12), source: "admin")
  end

  it "inserts one immutable event with an evt_ id and the current correlation id" do
    Thread.current[:correlation_id] = "corr-77"
    event = record!
    expect(event.id).to start_with("evt_")
    expect(event.correlation_id).to eq("corr-77")
    expect { MockPms.db[:events].where(seq: event.seq).update(type: "lease.updated") }
      .to raise_error(Sequel::DatabaseError, /immutable/)
  ensure
    Thread.current[:correlation_id] = nil
  end

  it "fans out one pending delivery per subscribed client with an active grant for the operator" do
    subscribed = subscribed_client(op)
    no_url = Factory.client.first
    Factory.tokens(no_url, op)
    revoked = subscribed_client(op)
    MockPms::OAuth::Service.revoke!(MockPms::Grant.active.first(client_seq: revoked.seq))
    other = subscribed_client(other_op)

    freeze_time(Time.utc(2026, 10, 1, 12, 5))
    event = record!
    deliveries = MockPms::Delivery.where(event_seq: event.seq).all
    expect(deliveries.map(&:client_seq)).to eq([subscribed.seq])
    expect(deliveries.first.values).to include(status: "pending", attempt_count: 0, replay: false,
                                               scheduled_at: Time.utc(2026, 10, 1, 12, 5))
    expect(deliveries.first.chaos.to_h).to eq({})
    expect(deliveries.first.id).to start_with("dlv_")
    expect(MockPms::Delivery.where(client_seq: other.seq).count).to eq(0)
  end

  it "leaves nothing behind when the business change rolls back" do
    subscribed_client(op)
    MockPms.db.transaction(savepoint: true, rollback: :always) { record! }
    expect(MockPms::Event.count).to eq(0)
    expect(MockPms::Delivery.count).to eq(0)
  end
end
