# frozen_string_literal: true

module Rentsync
  module Auth
    # Sign-in attempts per email and per IP, 5 a minute each, in the shared Redis bucket
    # (research R11). Without Redis, sign-in is refused rather than left unlimited.
    module SignInThrottle
      PER_MINUTE = 5

      module_function

      def allow?(email:, address:)
        by_email = RateLimit::Bucket.take("sign_in", "email", Digest::SHA256.hexdigest(email.to_s.strip.downcase),
                                          capacity: PER_MINUTE)
        by_ip = RateLimit::Bucket.take("sign_in", "ip", address.to_s, capacity: PER_MINUTE)
        by_email[:allowed] && by_ip[:allowed]
      rescue ::Redis::BaseError
        false
      end
    end
  end
end
