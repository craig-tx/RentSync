# frozen_string_literal: true

module Rentsync
  module Models
    # created_at from Rentsync::Clock (not the wall clock), so tests can freeze time.
    module Timestamps
      def before_create
        self.created_at ||= Clock.now if respond_to?(:created_at=)
        super
      end
    end

    # Public IDs ("<prefix>_<20 base32>") in public_id, assigned on create unless already set.
    module PublicId
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_reader :id_prefix

        def public_id_prefix(prefix)
          @id_prefix = prefix
        end
      end

      def before_create
        self.public_id ||= Ids.generate(self.class.id_prefix)
        super
      end
    end

    # Columns holding research R8's AES-GCM envelope. The associated data is
    # "<table>.<column>:<id>", so a row must exist before its secrets are written: create the
    # row, then call write_secrets! in the same transaction (create_with_secrets does both).
    module Encrypted
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def encrypted_columns(*columns)
          @encrypted_columns = columns.freeze
          columns.each do |column|
            define_method(:"#{column}_plaintext") { decrypt_column(column) }
          end
        end

        def encrypted = @encrypted_columns || []

        def create_with_secrets(attributes, secrets)
          db.transaction do
            row = create(attributes)
            row.write_secrets!(secrets)
            row
          end
        end
      end

      # Encrypts and stores each { column => plaintext or nil }.
      def write_secrets!(secrets)
        raise ArgumentError, "save the row before writing its secrets" unless id

        envelopes = secrets.to_h do |column, plaintext|
          raise ArgumentError, "#{column} is not an encrypted column" unless self.class.encrypted.include?(column)

          [column, plaintext.nil? ? nil : Crypto::Box.default.encrypt(plaintext, aad: aad(column))]
        end
        this.update(envelopes)
        envelopes.each { |column, envelope| values[column] = envelope }
        self
      end

      private

      def decrypt_column(column)
        envelope = self[column]
        envelope && Crypto::Box.default.decrypt(envelope, aad: aad(column))
      end

      def aad(column) = "#{self.class.table_name}.#{column}:#{id}"
    end

    def self.define(table, prefix: nil, &)
      Class.new(Sequel::Model(table)) do
        include Timestamps
        include Encrypted

        if prefix
          include PublicId

          public_id_prefix prefix
        end
        class_eval(&) if block_given?
      end
    end
  end
end
