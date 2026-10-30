# frozen_string_literal: true

module Rentsync
  # RentSync's registration with one PMS (research R9). Exactly one active row per pms_key.
  PmsClient = Models.define(:pms_clients) do
    encrypted_columns :client_secret, :signing_secret
    one_to_many :pms_connections, class: "Rentsync::PmsConnection", key: :pms_client_id

    dataset_module do
      def active = where(superseded_at: nil)
    end
  end
end
