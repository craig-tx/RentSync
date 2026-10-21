# frozen_string_literal: true

module MockPms
  Event = Models.define(:events, prefix: "evt") do
    many_to_one :operator, class: "MockPms::Operator", key: :operator_seq
    one_to_many :deliveries, class: "MockPms::Delivery", key: :event_seq
  end

  # Also the namespace for Delivery::Signer, ::RetrySchedule, ::Transport and ::Worker.
  Delivery = Models.define(:deliveries, prefix: "dlv") do
    many_to_one :event, class: "MockPms::Event", key: :event_seq
    many_to_one :client, class: "MockPms::Client", key: :client_seq
    one_to_many :attempts, class: "MockPms::DeliveryAttempt", key: :delivery_seq, order: :attempt_number

    dataset_module do
      def due(now) = where(status: "pending").where { scheduled_at <= now }.order(:scheduled_at, :seq)
    end
  end

  DeliveryAttempt = Models.define(:delivery_attempts) do
    many_to_one :delivery, class: "MockPms::Delivery", key: :delivery_seq
  end
end
