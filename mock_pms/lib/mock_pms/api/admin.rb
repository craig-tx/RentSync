# frozen_string_literal: true

module MockPms
  module API
    # /admin/* (ADMIN_TOKEN; exempt from rate limiting and chaos). Side-effecting POSTs
    # run under Idempotency-Key, except registration, whose response holds a secret.
    class Admin < Grape::API
      include AdminAuth

      helpers do
        def client_json(client)
          { client_id: client.id, name: client.name, redirect_uris: client.redirect_uris.to_a,
            subscriber_url: client.subscriber_url, rate_limit_per_minute: client.rate_limit_per_minute }
        end

        def grant_json(grant)
          { id: grant.id, client_id: grant.client.id, operator_id: grant.operator.id, scope: grant.scope,
            created_at: Presenters.time(grant.created_at), revoked_at: Presenters.time(grant.revoked_at) }
        end

        def find!(model, id)
          model.first(id: id.to_s) || api_error!("not_found", "#{id} not found", 404)
        end
      end

      namespace :admin do
        namespace :clients do
          params do
            requires :name, type: String, allow_blank: false
            requires :redirect_uris, type: [String], allow_blank: false
            optional :subscriber_url, type: String
            optional :rate_limit_per_minute, type: Integer
          end
          post do
            client, secret = MockPms::Clients.register!(
              name: params[:name], redirect_uris: params[:redirect_uris],
              subscriber_url: params[:subscriber_url], rate_limit_per_minute: params[:rate_limit_per_minute]
            )
            status 201
            client_json(client).merge(client_secret: secret, signing_secret: client.signing_secret)
          end

          get do
            MockPms::Client.order(:seq).map { |c| client_json(c) }
          end

          params do
            optional :subscriber_url, type: String
            optional :rate_limit_per_minute, type: Integer
            optional :redirect_uris, type: [String], allow_blank: false
          end
          patch ":client_id" do
            client = find!(MockPms::Client, params[:client_id])
            changes = {}
            changes[:subscriber_url] = params[:subscriber_url] if params.key?(:subscriber_url)
            changes[:rate_limit_per_minute] = params[:rate_limit_per_minute] if params.key?(:rate_limit_per_minute)
            changes[:redirect_uris] = Sequel.pg_array(params[:redirect_uris], :text) if params.key?(:redirect_uris)
            client.update(changes) unless changes.empty?
            client_json(client.refresh)
          end
        end

        namespace :grants do
          get do
            MockPms::Grant.order(:seq).eager(:client, :operator).all.map { |g| grant_json(g) }
          end

          post ":grant_id/revoke" do
            with_idempotency do
              grant = find!(MockPms::Grant, params[:grant_id])
              MockPms::OAuth::Service.revoke!(grant)
              [200, JSON.parse(JSON.generate(grant_json(grant)))]
            end
          end
        end
      end
    end
  end
end
