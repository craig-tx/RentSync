# frozen_string_literal: true

require "rack"

module Rentsync
  module API
    # Mounts every Grape API; the catch-all answers unknown routes with the error envelope.
    class Root < Grape::API
      include Errors

      mount Ops

      def self.mount_all(apis)
        apis.each { |api| mount api }
        route :any, "*path" do
          api_error!("not_found", "no route for #{request.request_method} #{request.path}", 404)
        end
      end
    end
  end

  # The Rack application. Order: correlation ID, request metrics, the webhook endpoint (US2),
  # session middleware (US1), the Grape API, then the pages.
  module App
    # Rack endpoints answered before any session or API code, by path (US2 adds the webhook).
    def self.endpoints = @endpoints ||= {}
    # Middleware between the endpoints and the API (US1 adds sessions).
    def self.middlewares = @middlewares ||= []
    # Grape APIs mounted after Ops (later stories add theirs).
    def self.apis = @apis ||= []

    def self.build
      @grape ||= begin
        API::Root.mount_all(apis)
        API::Root
      end
      grape = @grape
      routes = endpoints
      extra = middlewares
      Rack::Builder.new do
        use Middleware::CorrelationId
        use Middleware::RequestMetrics
        routes.each { |path, endpoint| map(path) { run endpoint } }
        map "/" do
          extra.each { |m| use m }
          run grape
        end
      end.to_app
    end
  end
end
