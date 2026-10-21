# frozen_string_literal: true

module MockPms
  module API
    # Admin authentication and helpers shared by every /admin endpoint.
    module AdminAuth
      def self.included(api)
        api.include Errors
        api.helpers Helpers
        api.before { authenticate_admin! }
      end

      module Helpers
        def authenticate_admin!
          header = headers["authorization"] || headers["Authorization"] || ""
          token = header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : ""
          return if Rack::Utils.secure_compare(token, Settings.admin_token)

          api_error!("unauthorized", "admin token required", 401)
        end

        # Runs the block under Idempotency-Key semantics and renders its [status, body].
        def with_idempotency(&)
          request.body.rewind
          raw = request.body.read
          request.body.rewind
          key = headers["idempotency-key"] || headers["Idempotency-Key"]
          code, body = MockPms::Admin::Idempotency.call(key: key, method: request.request_method,
                                                        path: request.path, body: raw, &)
          status code
          body
        end
      end
    end

    class AdminBase < Grape::API
      include AdminAuth

      get "/admin/status" do
        { status: "ok", service_version: Settings.service_version }
      end
    end
  end
end
