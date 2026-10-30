# frozen_string_literal: true

module Rentsync
  # A signed-in browser (research R11). The cookie token itself is never stored.
  Session = Models.define(:sessions) do
    many_to_one :operator, class: "Rentsync::Operator", key: :operator_id
  end
end
