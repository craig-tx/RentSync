# frozen_string_literal: true

require "securerandom"

module MockPms
  # Public identifiers: "<prefix>_" + 20 Crockford base32 characters (research R9).
  # Seeded rows pass their seeded Random so IDs are reproducible (R5).
  module Ids
    ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    LENGTH = 20

    module_function

    def generate(prefix, rng: nil)
      chars = Array.new(LENGTH) do
        ALPHABET[rng ? rng.rand(ALPHABET.size) : SecureRandom.random_number(ALPHABET.size)]
      end
      "#{prefix}_#{chars.join}"
    end
  end
end
