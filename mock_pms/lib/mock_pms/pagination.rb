# frozen_string_literal: true

require "base64"

module MockPms
  # Keyset pagination on the immutable seq, ascending (research R9). Filters only
  # narrow the dataset; ordering never changes, so rows that existed when paging
  # began are never skipped or repeated.
  module Pagination
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200

    class Invalid < StandardError; end

    module_function

    def paginate(dataset, limit:, cursor:)
      limit = parse_limit(limit)
      after = parse_cursor(cursor)
      scoped = after ? dataset.where { seq > after } : dataset
      rows = scoped.order(:seq).limit(limit + 1).all
      more = rows.size > limit
      rows = rows.first(limit)
      [rows, more ? encode(rows.last.seq) : nil]
    end

    def encode(seq) = Base64.urlsafe_encode64(seq.to_s, padding: false)

    def parse_limit(value)
      return DEFAULT_LIMIT if value.nil? || value.to_s.empty?

      n = Integer(value.to_s, exception: false)
      raise Invalid, "limit must be an integer between 1 and #{MAX_LIMIT}" unless n&.between?(1, MAX_LIMIT)

      n
    end

    def parse_cursor(value)
      return nil if value.nil? || value.to_s.empty?

      decoded = Base64.urlsafe_decode64(value.to_s)
      Integer(decoded, exception: false) || raise(Invalid, "malformed cursor")
    rescue ArgumentError
      raise Invalid, "malformed cursor"
    end
  end
end
