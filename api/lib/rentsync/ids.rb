# frozen_string_literal: true

require "securerandom"

module Rentsync
  # Public identifiers: "<prefix>_" + 20 Crockford base32 characters, as in the mock PMS
  # (001 research R9): opr_ for operators, con_ for connections (data-model.md).
  module Ids
    ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    LENGTH = 20

    module_function

    def generate(prefix)
      chars = Array.new(LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }
      "#{prefix}_#{chars.join}"
    end
  end
end
