# frozen_string_literal: true

module Rentsync
  module Pms
    # Makes sure this deployment has exactly one active PMS client (research R9):
    #   - none: register one;
    #   - one the PMS still lists: keep it;
    #   - one the PMS no longer lists (a mock reset): supersede it, register again, and send the
    #     live connections under it to needs_reauth.
    # Runs under a transaction-scoped advisory lock, so concurrent runs make one registration.
    class Registration
      include Logging::Loggable

      PMS_KEY = "mock_pms"
      LOCK_KEY = 4_002_009

      def initialize(admin: AdminApi.new)
        @admin = admin
      end

      # Returns { action: :registered | :kept | :replaced, client_id: }.
      def ensure!
        Rentsync.db.transaction do
          Rentsync.db.get(Sequel.function(:pg_advisory_xact_lock, LOCK_KEY))
          current = PmsClient.active.first(pms_key: PMS_KEY)
          next result(:kept, current) if current && @admin.client_ids.include?(current.client_id)

          retire(current) if current
          result(current ? :replaced : :registered, register)
        end
      end

      # Stores credentials a PMS handed over out of band (bin/pms_client --set), replacing the
      # active client. Returns the same shape as ensure!.
      def install!(client_id:, client_secret:, signing_secret:)
        Rentsync.db.transaction do
          Rentsync.db.get(Sequel.function(:pg_advisory_xact_lock, LOCK_KEY))
          current = PmsClient.active.first(pms_key: PMS_KEY)
          retire(current) if current
          result(current ? :replaced : :registered, store(client_id, client_secret, signing_secret))
        end
      end

      private

      def register
        response = @admin.create_client(
          name: "rentsync-#{Settings.deployment_id}",
          redirect_uris: [Pms.redirect_uri],
          subscriber_url: Settings.webhook_subscriber_url
        )
        store(response.fetch("client_id"), response.fetch("client_secret"), response.fetch("signing_secret"))
      end

      def store(client_id, client_secret, signing_secret)
        PmsClient.create_with_secrets(
          { pms_key: PMS_KEY, base_url: Settings.pms_public_url, client_id: client_id, registered_at: Clock.now },
          client_secret: client_secret, signing_secret: signing_secret
        )
      end

      def retire(client)
        client.update(superseded_at: Clock.now)
        sent = PmsConnection.where(pms_client_id: client.id, status: PmsConnection::LIVE)
                            .update(status: "needs_reauth")
        log.warn("PMS client no longer registered; superseded", client_id: client.client_id,
                                                                connections_needing_reauth: sent)
      end

      def result(action, client)
        log.info("PMS client #{action}", client_id: client.client_id) unless action == :kept
        { action: action, client_id: client.client_id }
      end
    end
  end
end
