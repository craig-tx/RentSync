# frozen_string_literal: true

require "rack"

module MockPms
  # Mounts every Grape API; the catch-all answers unknown routes with the envelope.
  module API
    class Root < Grape::API
      include Errors

      mount Ops
      mount AdminBase

      def self.mount_all(apis)
        apis.each { |api| mount api }
        route :any, "*path" do
          api_error!("not_found", "no route for #{request.request_method} #{request.path}", 404)
        end
      end
    end
  end

  # The Rack application (research R8, R12):
  # CorrelationId -> RequestMetrics -> RateLimiter -> ChaosErrors -> Grape.
  module App
    # APIs mounted after the foundation (OAuth, V1, Admin) register here.
    def self.apis = @apis ||= [API::OAuth, API::V1, API::Admin]

    def self.middlewares = @middlewares ||= [Middleware::RateLimiter]

    def self.build
      @grape ||= begin
        API::Root.mount_all(apis)
        API::Root
      end
      grape = @grape
      extra = middlewares
      Rack::Builder.new do
        use Middleware::CorrelationId
        use Middleware::RequestMetrics
        extra.each { |m| use m }
        run grape
      end.to_app
    end
  end
end
