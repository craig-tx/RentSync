# frozen_string_literal: true

module MockPms
  Client = Models.define(:clients, prefix: "client") do
    one_to_many :grants, class: "MockPms::Grant", key: :client_seq
  end

  Grant = Models.define(:grants, prefix: "grant") do
    many_to_one :client, class: "MockPms::Client", key: :client_seq
    many_to_one :operator, class: "MockPms::Operator", key: :operator_seq

    dataset_module do
      def active = where(revoked_at: nil)
    end

    def active? = revoked_at.nil?
  end

  AuthorizationCode = Models.define(:authorization_codes) { unrestrict_primary_key }
  AccessToken = Models.define(:access_tokens) { unrestrict_primary_key }
  RefreshToken = Models.define(:refresh_tokens) { unrestrict_primary_key }
end
