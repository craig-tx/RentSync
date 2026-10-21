# frozen_string_literal: true

module MockPms
  module Models
    # created_at/updated_at from MockPms::Clock (not the wall clock), so tests can
    # freeze time and the seed can write historical timestamps explicitly.
    module Timestamps
      def before_create
        now = Clock.now
        self.created_at ||= now if respond_to?(:created_at=)
        self.updated_at ||= created_at || now if respond_to?(:updated_at=)
        super
      end

      def before_update
        self.updated_at = Clock.now if respond_to?(:updated_at=) && !changed_columns.include?(:updated_at)
        super
      end
    end

    # Public ids ("<prefix>_<20 base32>") assigned on create unless already set.
    module PublicId
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_reader :id_prefix

        def public_id(prefix)
          @id_prefix = prefix
        end
      end

      def before_create
        self.id ||= Ids.generate(self.class.id_prefix)
        super
      end
    end

    def self.define(table, prefix: nil, &)
      Class.new(Sequel::Model(table)) do
        include Timestamps

        if prefix
          include PublicId

          public_id prefix
        end
        class_eval(&) if block_given?
      end
    end
  end
end
