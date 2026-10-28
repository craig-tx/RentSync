# frozen_string_literal: true

require "grape"

module Rentsync
  module API
    # The error envelope for every non-OAuth error: {"error":{"code","message"}}.
    module Errors
      def self.body(code, message) = { error: { code: code, message: message } }

      module Helpers
        def api_error!(code, message, status, headers = {})
          error!(Errors.body(code, message), status, headers)
        end
      end

      # Shared setup for every Grape API in the service.
      def self.included(api)
        api.format :json
        api.default_format :json
        api.helpers Helpers
        api.rescue_from Grape::Exceptions::ValidationErrors do |e|
          error!(Errors.body("invalid_parameter", e.full_messages.join(", ")), 422)
        end
        api.rescue_from Grape::Exceptions::Base do |e|
          error!(Errors.body("bad_request", e.message), e.status || 400)
        end
        api.rescue_from :all do |e|
          Logging.for_function("Rentsync::API::Errors#rescue").error("unhandled error", error: e.class.name,
                                                                                        detail: e.message)
          error!(Errors.body("internal_error", "internal server error"), 500)
        end
      end
    end
  end
end
