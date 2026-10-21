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

        def delivery_json(delivery)
          {
            id: delivery.id, event_id: delivery.event.id, client_id: delivery.client.id, status: delivery.status,
            attempt_count: delivery.attempt_count, replay: delivery.replay, chaos: delivery.chaos.to_h,
            scheduled_at: Presenters.time(delivery.scheduled_at),
            attempts: delivery.attempts.map do |a|
              { attempt_number: a.attempt_number, started_at: Presenters.time(a.started_at),
                finished_at: Presenters.time(a.finished_at), outcome: a.outcome, http_status: a.http_status }
            end
          }
        end

        def seq_of(model, id) = model.where(id: id.to_s).get(:seq) || 0

        def paged(dataset)
          rows, cursor = Pagination.paginate(dataset, limit: params[:limit], cursor: params[:cursor])
          [rows, cursor]
        rescue Pagination::Invalid => e
          api_error!("invalid_parameter", e.message, 422)
        end

        def json_safe(value) = JSON.parse(JSON.generate(value))
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
              [200, json_safe(grant_json(grant))]
            end
          end
        end

        namespace :chaos do
          get { Chaos::Settings.current }

          put do
            changes = params.slice(*Chaos::Settings::FIELDS.map(&:to_s)).to_h
            Chaos::Settings.update!(changes)
          rescue Chaos::Invalid, ArgumentError, TypeError => e
            api_error!("invalid_parameter", e.message, 422)
          end
        end

        post "events/:event_id/replay" do
          with_idempotency do
            event = find!(MockPms::Event, params[:event_id])
            client = find!(MockPms::Client, params[:client_id])
            delivery = Events::Replayer.replay_one!(event: event, client: client)
            [202, json_safe(delivery_json(delivery))]
          rescue Events::Replayer::Conflict => e
            [409, json_safe(Errors.body("conflict", e.message))]
          end
        end

        post :replays do
          with_idempotency do
            client = find!(MockPms::Client, params[:client_id])
            from = Time.iso8601(params[:from].to_s)
            to = Time.iso8601(params[:to].to_s)
            queued = Events::Replayer.replay_range!(client: client, from: from, to: to, types: params[:types])
            [202, { "queued" => queued }]
          rescue Events::Replayer::Conflict => e
            [409, json_safe(Errors.body("conflict", e.message))]
          rescue ArgumentError
            [422, json_safe(Errors.body("invalid_parameter", "from and to must be ISO 8601 date-times"))]
          end
        end

        post :reset do
          with_idempotency do
            seed = params[:seed] ? Integer(params[:seed]) : Settings.seed
            anchor = params[:anchor_date] ? Date.iso8601(params[:anchor_date].to_s) : Settings.seed_anchor_date
            [200, json_safe(Seed::Reset.run!(seed: seed, anchor_date: anchor))]
          rescue ArgumentError
            [422, json_safe(Errors.body("invalid_parameter", "seed must be an integer; anchor_date YYYY-MM-DD"))]
          end
        end

        get :events do
          dataset = MockPms::Event.dataset
          dataset = dataset.where(type: params[:type].to_s) if params[:type]
          dataset = dataset.where(operator_seq: seq_of(MockPms::Operator, params[:operator_id])) if params[:operator_id]
          if params[:since]
            since = begin
              Time.iso8601(params[:since].to_s)
            rescue ArgumentError
              api_error!("invalid_parameter", "since must be an ISO 8601 date-time", 422)
            end
            dataset = dataset.where { occurred_at >= since }
          end
          rows, cursor = paged(dataset.eager(:operator))
          { data: rows.map { |e| Events::Serializer.envelope(e) }, next_cursor: cursor }
        end

        get :deliveries do
          dataset = MockPms::Delivery.dataset
          dataset = dataset.where(client_seq: seq_of(MockPms::Client, params[:client_id])) if params[:client_id]
          dataset = dataset.where(event_seq: seq_of(MockPms::Event, params[:event_id])) if params[:event_id]
          dataset = dataset.where(status: params[:status].to_s) if params[:status]
          rows, cursor = paged(dataset.eager(:event, :client, :attempts))
          { data: rows.map { |d| delivery_json(d) }, next_cursor: cursor }
        end

        post "scenarios/:name" do
          scenario = Scenarios.registry[params[:name]]
          api_error!("not_found", "unknown scenario #{params[:name]}", 404) unless scenario
          options = params.slice(:operator_id, :share, :count, :window_s).to_h.transform_keys(&:to_sym).compact
          with_idempotency { [200, json_safe(scenario.run!(**options))] }
        end
      end
    end
  end
end
