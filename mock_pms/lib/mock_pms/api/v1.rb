# frozen_string_literal: true

module MockPms
  module API
    # Read-only, operator-scoped data API (FR-008, FR-009). Every dataset is scoped to
    # the token's operator; another operator's record is indistinguishable from 404.
    class V1 < Grape::API
      include Errors

      RESOURCES = {
        "properties" => [MockPms::Property, :property],
        "tenants" => [MockPms::Tenant, :tenant],
        "leases" => [MockPms::Lease, :lease],
        "charges" => [MockPms::Charge, :charge],
        "payments" => [MockPms::Payment, :payment]
      }.freeze

      rescue_from(Pagination::Invalid) { |e| error!(Errors.body("invalid_parameter", e.message), 422) }

      helpers do
        def authenticate!
          header = headers["authorization"] || headers["Authorization"] || ""
          raw = header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : nil
          status, grant = env["mock_pms.token_check"] || MockPms::OAuth::Service.validate_access_token(raw)
          return remember(grant) if status == :valid

          description = status == :expired ? "token expired" : "token invalid"
          api_error!("unauthorized", description, 401,
                     "WWW-Authenticate" => %(Bearer error="invalid_token", error_description="#{description}"))
        end

        def remember(grant)
          env["mock_pms.operator_seq"] = grant.operator_seq
          env["mock_pms.client_seq"] = grant.client_seq
        end

        def scoped(model) = model.where(operator_seq: env["mock_pms.operator_seq"])

        def public_seq(model, id)
          model.where(operator_seq: env["mock_pms.operator_seq"], id: id.to_s).get(:seq) || 0
        end

        def time_param(name)
          params[name] && Time.iso8601(params[name].to_s)
        rescue ArgumentError
          raise Pagination::Invalid, "#{name} must be an ISO 8601 date-time"
        end

        def date_param(name)
          params[name] && Date.iso8601(params[name].to_s)
        rescue Date::Error
          raise Pagination::Invalid, "#{name} must be an ISO 8601 date"
        end

        def filtered(resource, dataset)
          if (since = time_param(:updated_since))
            dataset = dataset.where { updated_at >= since }
          end
          case resource
          when :lease then lease_filters(dataset)
          when :charge then charge_filters(by_lease(dataset))
          when :payment then payment_filters(by_lease(dataset))
          else dataset
          end
        end

        def lease_filters(dataset)
          if params[:property_id]
            dataset = dataset.where(property_seq: public_seq(MockPms::Property,
                                                             params[:property_id]))
          end
          dataset = dataset.where(tenant_seq: public_seq(MockPms::Tenant, params[:tenant_id])) if params[:tenant_id]
          dataset = dataset.where(status: params[:status].to_s) if params[:status]
          dataset
        end

        def charge_filters(dataset)
          from = date_param(:from)
          to = date_param(:to)
          dataset = dataset.where { due_date >= from } if from
          dataset = dataset.where { due_date <= to } if to
          dataset
        end

        def payment_filters(dataset)
          from = time_param(:from)
          to = time_param(:to)
          dataset = dataset.where { received_at >= from } if from
          dataset = dataset.where { received_at < to } if to
          dataset
        end

        def by_lease(dataset)
          params[:lease_id] ? dataset.where(lease_seq: public_seq(MockPms::Lease, params[:lease_id])) : dataset
        end

        def list(name)
          model, resource = RESOURCES.fetch(name)
          dataset = Presenters.eager(resource, filtered(resource, scoped(model)))
          rows, cursor = Pagination.paginate(dataset, limit: params[:limit], cursor: params[:cursor])
          { data: rows.map { |row| Presenters.public_send(resource, row) }, next_cursor: cursor }
        end
      end

      before { authenticate! }

      namespace :v1 do
        RESOURCES.each_key do |name|
          get(name) { list(name) }
        end

        get ":resource/:id", requirements: { resource: /#{RESOURCES.keys.join('|')}/ } do
          model, resource = RESOURCES.fetch(params[:resource])
          row = Presenters.eager(resource, scoped(model).where(id: params[:id].to_s)).all.first
          api_error!("not_found", "#{params[:resource]} #{params[:id]} not found", 404) unless row
          Presenters.public_send(resource, row)
        end
      end
    end
  end
end
