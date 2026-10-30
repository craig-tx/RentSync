# frozen_string_literal: true

require "digest"
require "openssl"

module Rentsync
  module API
    # /admin/* for ops and test tooling (contracts/openapi.yaml "Admin"): raw event metadata to
    # compare with the PMS's true events (quickstart §3), and receipt counts. Never payloads.
    class Admin < Grape::API
      include Errors

      MAX_LIMIT = 500

      helpers do
        # Bearer ADMIN_TOKEN, compared as SHA-256 digests so the lengths always match.
        def authenticate!
          header = headers["authorization"] || headers["Authorization"] || ""
          token = header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : ""
          given = Digest::SHA256.digest(token)
          expected = Digest::SHA256.digest(Settings.admin_token)
          return if !token.empty? & OpenSSL.fixed_length_secure_compare(given, expected)

          api_error!("unauthorized", "admin token required", 401)
        end

        def page_params
          limit = Integer(params.fetch(:limit, 100).to_s, 10)
          cursor = params[:cursor] && Integer(params[:cursor].to_s, 10)
          raise ArgumentError unless limit.between?(1, MAX_LIMIT)

          [limit, cursor]
        rescue ArgumentError
          api_error!("invalid_parameter", "limit is 1 to #{MAX_LIMIT}; cursor comes from next_cursor", 422)
        end
      end

      namespace :admin do
        before { authenticate! }

        get :raw_events do
          limit, cursor = page_params
          events = Sequel[:raw_events]
          columns = [events[:id], :event_id, :business_key, :event_type, :occurred_at, :arrival_path, :pms_operator_id]
          dataset = Rentsync.db[:raw_events].join(:pms_connections, id: :connection_id)
          dataset = dataset.select(*columns).order(events[:id]).limit(limit + 1)
          dataset = dataset.where(pms_operator_id: params[:pms_operator_id].to_s) if params[:pms_operator_id]
          dataset = dataset.where(events[:id] > cursor) if cursor
          rows = dataset.all
          more = rows.size > limit
          rows = rows.first(limit)
          { data: rows.map { |r| r.except(:id).merge(occurred_at: r[:occurred_at].utc.iso8601) },
            next_cursor: more ? rows.last[:id].to_s : nil }
        end

        get :receipts do
          counts = Rentsync.db[:webhook_receipts].group_and_count(:outcome, :reason).order(:outcome, :reason).all
          { counts: counts, total: counts.sum { |c| c[:count] } }
        end
      end
    end
  end

  App.apis << API::Admin
end
