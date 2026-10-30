# frozen_string_literal: true

require "bcrypt"

module Rentsync
  module Auth
    # Operator passwords, stored only as bcrypt digests (research R11).
    module Passwords
      module_function

      def cost = Settings.test? ? BCrypt::Engine::MIN_COST : BCrypt::Engine::DEFAULT_COST

      # Computed once at load, so every unknown-email check costs one bcrypt comparison.
      DUMMY = BCrypt::Password.create("not-a-real-password", cost: cost).to_s

      def digest(password) = BCrypt::Password.create(password, cost: cost).to_s

      # The operator for this email and password, or nil. An unknown email is checked against a
      # dummy digest, so it takes as long as a wrong password and reveals nothing.
      def authenticate(email, password)
        operator = Operator.first(Sequel.function(:lower, :email) => email.to_s.strip.downcase)
        candidate = BCrypt::Password.new(operator&.password_digest || DUMMY)
        operator if candidate == password.to_s && operator
      end
    end
  end
end
