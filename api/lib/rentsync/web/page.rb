# frozen_string_literal: true

require "erb"

module Rentsync
  module Web
    # Server-rendered pages (research R12): ERB views inside one layout, everything escaped with
    # h(). Templates are compiled once at load, so Puma's threads share them read-only.
    class Page
      include ERB::Util

      VIEWS = File.expand_path("views", __dir__)
      TEMPLATES = %w[layout sign_in connections message].to_h do |name|
        [name, ERB.new(File.read(File.join(VIEWS, "#{name}.html.erb")), trim_mode: "-")]
      end.freeze

      # Renders view `name` inside the layout. The layout needs title, signed_in and csrf.
      def self.render(name, **locals)
        body = new(locals).result(name)
        new(locals.merge(body: body)).result("layout")
      end

      def initialize(locals)
        locals.each { |key, value| define_singleton_method(key) { value } }
      end

      def result(name) = TEMPLATES.fetch(name).result(binding)

      def time(value) = value&.utc&.strftime("%Y-%m-%d %H:%M UTC")
    end
  end
end
