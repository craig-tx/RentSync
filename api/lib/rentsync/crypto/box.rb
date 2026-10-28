# frozen_string_literal: true

require "openssl"

module Rentsync
  module Crypto
    # AES-256-GCM envelopes for the secrets RentSync must present again (research R8).
    #
    #   v1:<key_id>:<base64 nonce>:<base64 ciphertext+tag>
    #
    # The associated data names the row and column ("pms_connections.refresh_token:42"), so a
    # ciphertext copied to another row or column fails to decrypt. Keys come from
    # RENTSYNC_ENCRYPTION_KEYS ("key_id=base64key,..."): the first encrypts, every one decrypts.
    # Errors never include a key or a plaintext.
    class Box
      class Error < StandardError; end
      class ConfigError < Error; end

      VERSION = "v1"
      CIPHER = "aes-256-gcm"
      KEY_BYTES = 32
      NONCE_BYTES = 12
      TAG_BYTES = 16
      KEY_ID = /\A[A-Za-z0-9_-]{1,32}\z/

      # The box for this process's configured keys.
      def self.default = @default ||= new(Settings.encryption_keys)

      def initialize(config)
        @keys = parse(config.to_s)
        @current = @keys.keys.first
      end

      def encrypt(plaintext, aad:)
        cipher = OpenSSL::Cipher.new(CIPHER).encrypt
        cipher.key = @keys.fetch(@current)
        nonce = cipher.random_iv
        cipher.auth_data = aad.to_s
        sealed = cipher.update(plaintext.to_s.b) + cipher.final + cipher.auth_tag(TAG_BYTES)
        [VERSION, @current, encode(nonce), encode(sealed)].join(":")
      end

      def decrypt(envelope, aad:)
        version, key_id, nonce, sealed = envelope.to_s.split(":", 4)
        raise Error, "not a #{VERSION} envelope" unless version == VERSION && nonce && sealed

        key = @keys[key_id] or raise Error, "envelope uses key #{key_id}, which is not configured"
        unseal(key, decode(nonce), decode(sealed), aad.to_s)
      end

      private

      def unseal(key, nonce, sealed, aad)
        raise Error, "malformed envelope" unless nonce.bytesize == NONCE_BYTES && sealed.bytesize >= TAG_BYTES

        cipher = OpenSSL::Cipher.new(CIPHER).decrypt
        cipher.key = key
        cipher.iv = nonce
        cipher.auth_tag = sealed.byteslice(-TAG_BYTES, TAG_BYTES)
        cipher.auth_data = aad
        (cipher.update(sealed.byteslice(0, sealed.bytesize - TAG_BYTES)) + cipher.final).force_encoding(Encoding::UTF_8)
      rescue OpenSSL::Cipher::CipherError
        raise Error, "envelope does not authenticate (wrong key, row or column, or tampered)"
      end

      def parse(config)
        entries = config.split(",").map(&:strip)
        raise ConfigError, "RENTSYNC_ENCRYPTION_KEYS is empty" if entries.empty?

        entries.each_with_index.with_object({}) do |(entry, i), keys|
          id, encoded = entry.split("=", 2)
          where = "RENTSYNC_ENCRYPTION_KEYS entry #{i + 1}"
          raise ConfigError, "#{where} must be key_id=base64key with a key ID of letters, digits, _ or -" \
            unless id && KEY_ID.match?(id) && encoded && !encoded.empty?
          raise ConfigError, "#{where} repeats key ID #{id}" if keys.key?(id)

          keys[id] = decode_key(encoded, where)
        end
      end

      def decode_key(encoded, where)
        key = encoded.unpack1("m0")
        raise ConfigError, "#{where} must decode to #{KEY_BYTES} bytes" unless key.bytesize == KEY_BYTES

        key
      rescue ArgumentError
        raise ConfigError, "#{where} is not valid base64"
      end

      def encode(bytes) = [bytes].pack("m0")

      def decode(text)
        text.unpack1("m0")
      rescue ArgumentError
        raise Error, "malformed envelope"
      end
    end
  end
end
