# frozen_string_literal: true

module Rentsync
  # One try at connecting (research R7): single use, valid for 10 minutes.
  ConnectionAttempt = Models.define(:connection_attempts) do
    encrypted_columns :code_verifier
    many_to_one :operator, class: "Rentsync::Operator", key: :operator_id
  end

  class ConnectionAttempt
    TTL_S = 600
    OUTCOMES = %w[connected denied failed expired].freeze
  end
end
