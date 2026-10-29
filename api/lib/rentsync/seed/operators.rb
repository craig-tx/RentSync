# frozen_string_literal: true

module Rentsync
  module Seed
    # One RentSync operator per mock PMS operator (T030, research R11). The mock's seed is fixed
    # (mock_pms/lib/mock_pms/seed/wordlists.rb), so this list is too. bin/connect_operator uses
    # the same list to sign in on both sides, so it loads without a database.
    module Operators
      LIST = [
        { name: "Lone Star Rentals", pms_login: "lonestar" },
        { name: "Prairie Homes", pms_login: "prairie" },
        { name: "Bluebonnet Property Co", pms_login: "bluebonnet" }
      ].freeze

      module_function

      def email(number) = "operator#{number}@example.test"

      def pms_login(number)
        raise ArgumentError, "operator must be 1 to #{LIST.size}" unless number.between?(1, LIST.size)

        LIST[number - 1][:pms_login]
      end

      # Creates the missing operators with RENTSYNC_OPERATOR_SEED_PASSWORD; leaves existing ones
      # unchanged. Returns every seeded operator.
      def ensure!
        digest = nil
        LIST.each_with_index.map do |spec, i|
          email = email(i + 1)
          Operator.first(email: email) ||
            Operator.create(email: email, name: spec[:name],
                            password_digest: digest ||= Auth::Passwords.digest(Settings.operator_seed_password))
        end
      end
    end
  end
end
