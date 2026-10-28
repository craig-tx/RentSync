# frozen_string_literal: true

module Rentsync
  # A RentSync user: one property management company (data-model.md). Seeded, no sign-up.
  Operator = Models.define(:operators, prefix: "opr") do
    one_to_many :pms_connections, class: "Rentsync::PmsConnection", key: :operator_id
  end
end
