# frozen_string_literal: true

module Rentsync
  # One RentSync operator linked to one PMS operator (data-model.md state machine).
  PmsConnection = Models.define(:pms_connections, prefix: "con") do
    encrypted_columns :access_token, :refresh_token
    many_to_one :operator, class: "Rentsync::Operator", key: :operator_id
    many_to_one :pms_client, class: "Rentsync::PmsClient", key: :pms_client_id
  end

  class PmsConnection
    STATUSES = %w[active renewal_failing needs_reauth disconnected].freeze
    # Only these are reconciled and accept webhooks.
    LIVE = %w[active renewal_failing].freeze
  end
end
