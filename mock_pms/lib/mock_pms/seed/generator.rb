# frozen_string_literal: true

require "bcrypt"

module MockPms
  module Seed
    # Builds the seed portfolio from (seed, anchor_date) alone (research R5): one
    # Random for every draw, public ids from that Random, and every timestamp from
    # the simulated history — never the wall clock. Writes through datasets in a
    # fixed order, so the same inputs always produce identical rows.
    class Generator
      include Logging::Loggable
      include Wordlists

      METHODS = %w[ach ach ach card check money_order].freeze
      LATE_DAYS = [3, 7, 12, 20].freeze
      # Guaranteed early in the run so every behavior category exists (T033).
      FORCED = %i[late_3 late_7 late_12 late_20 partial_completed partial_never nsf_repaid nsf_unpaid
                  partial_nsf unpaid on_time].freeze
      MOVE_OUTS = 4
      NORMAL_TURNOVERS = 6

      def self.run(seed:, anchor_date:) = new(seed, anchor_date).run

      def initialize(seed, anchor_date)
        @seed = seed
        @rng = Random.new(seed)
        @anchor = anchor_date
        @anchor_month = Date.new(anchor_date.year, anchor_date.month, 1)
        @window_start = @anchor_month << 11
        @end_of_anchor = Time.utc(anchor_date.year, anchor_date.month, anchor_date.day, 23, 59, 59)
        @forced = FORCED.dup
        @db = MockPms.db
      end

      def run
        @db.transaction do
          operators = OPERATORS.map { |spec| create_operator(spec) }
          properties = operators.flat_map { |op, spec| Array.new(spec[:properties]) { create_property(op) } }
          turnovers = properties.sample(MOVE_OUTS + NORMAL_TURNOVERS, random: @rng)
          properties.each do |property|
            index = turnovers.index(property)
            if index
              first_end = turnover_lease(property, move_out: index < MOVE_OUTS)
              create_lease(property, start: first_end.next_month.then { |d| Date.new(d.year, d.month, 1) })
            else
              create_lease(property, start: @window_start << @rng.rand(0..11), extend_past_anchor: true)
            end
          end
          create_seed_events
        end
        log.info("seed generated", seed_anchor: @anchor.iso8601)
      end

      private

      def id(prefix) = Ids.generate(prefix, rng: @rng)

      def at(date, hour = 9) = Time.utc(date.year, date.month, date.day, hour + @rng.rand(8), @rng.rand(60))

      def insert(table, row) = @db[table].insert(row)

      def create_operator(spec)
        created = at(@window_start << 24)
        seq = insert(:operators, id: id("op"), name: spec[:name], login: spec[:login],
                                 password_digest: BCrypt::Password.create("#{spec[:login]}-pass", cost: 4),
                                 timezone: "America/Chicago", created_at: created, updated_at: created)
        [seq, spec]
      end

      def create_property((operator_seq, _spec))
        city, zip_prefix = CITIES[@rng.rand(CITIES.size)]
        created = at(@window_start << 18)
        row = {
          id: id("prop"), operator_seq: operator_seq,
          address_line1: "#{@rng.rand(100..9999)} #{STREETS[@rng.rand(STREETS.size)]} " \
                         "#{STREET_TYPES[@rng.rand(STREET_TYPES.size)]}",
          city: city, state: "TX",
          postal_code: format("%<prefix>s%<suffix>02d", prefix: zip_prefix, suffix: @rng.rand(100)),
          bedrooms: @rng.rand(2..5), bathrooms: [1.0, 1.5, 2.0, 2.5, 3.0][@rng.rand(5)], status: "occupied",
          created_at: created, updated_at: created
        }
        row.merge(seq: insert(:properties, row))
      end

      # First lease on a turnover property; returns the date it ended.
      def turnover_lease(property, move_out:)
        start = @window_start << @rng.rand(move_out ? 1..6 : 1..9)
        scheduled_end = start.next_year - 1
        actual_end = move_out ? move_out_date(start, scheduled_end) : nil
        create_lease(property, start: start, scheduled_end: scheduled_end, actual_end: actual_end)
        actual_end || scheduled_end
      end

      def move_out_date(start, scheduled_end)
        months = (0..11).map { |i| @window_start >> i }
                        .select { |m| m > (start >> 2) && (m >> 1) <= scheduled_end && m < @anchor_month }
        month = months[@rng.rand(months.size)]
        Date.new(month.year, month.month, 15)
      end

      # extend_past_anchor: single-lease properties get a 24-month term when a 12-month
      # term would already have ended, so they stay active through the anchor date.
      def create_lease(property, start:, scheduled_end: nil, actual_end: nil, extend_past_anchor: false)
        scheduled_end ||= start.next_year - 1
        scheduled_end = start.next_year(2) - 1 if extend_past_anchor && scheduled_end < @anchor
        status = lease_status(start, scheduled_end, actual_end)
        tenant_seq = create_tenant(property, start, status)
        created = at(start - 14)
        updated = if actual_end
                    at(actual_end)
                  else
                    (status == "ended" ? at(scheduled_end + 1) : created)
                  end
        lease = {
          id: id("lease"), operator_seq: property[:operator_seq], property_seq: property[:seq],
          tenant_seq: tenant_seq, start_date: start, scheduled_end_date: scheduled_end,
          actual_end_date: actual_end, monthly_rent_cents: @rng.rand(48..112) * 2500, currency: "USD",
          due_day: @rng.rand < 0.85 ? 1 : 5, grace_days: 3, late_fee_cents: 7500, status: status,
          created_at: created, updated_at: updated
        }
        lease[:seq] = insert(:leases, lease)
        create_month_history(lease)
      end

      def lease_status(start, scheduled_end, actual_end)
        return "ended_early" if actual_end
        return "pending" if start > @anchor
        return "ended" if scheduled_end < @anchor

        "active"
      end

      def create_tenant(property, start, status)
        first = FIRST_NAMES[@rng.rand(FIRST_NAMES.size)]
        last = LAST_NAMES[@rng.rand(LAST_NAMES.size)]
        created = at(start - 21)
        insert(:tenants, id: id("ten"), operator_seq: property[:operator_seq], first_name: first, last_name: last,
                         email: "#{first.downcase}.#{last.downcase}#{@rng.rand(1000)}@example.test",
                         phone: format("555-01%02d", @rng.rand(100)),
                         status: %w[active pending].include?(status) ? "current" : "former",
                         created_at: created, updated_at: created)
      end

      def create_month_history(lease)
        last_day = lease[:actual_end_date] || lease[:scheduled_end_date]
        month = [@window_start, Date.new(lease[:start_date].year, lease[:start_date].month, 1)].max
        while month <= @anchor_month && month <= last_day
          due = Date.new(month.year, month.month, lease[:due_day])
          created = Time.utc(due.year, due.month, due.day, 6) - (10 * 86_400)
          break if created > @end_of_anchor

          charge = create_charge(lease, kind: "rent", period: month, due: due, amount: lease[:monthly_rent_cents],
                                        created: created)
          play_behavior(lease, charge) if due <= @anchor
          month >>= 1
        end
      end

      def create_charge(lease, kind:, period:, due:, amount:, created:)
        row = { id: id("chg"), operator_seq: lease[:operator_seq], lease_seq: lease[:seq], kind: kind,
                period: period, due_date: due, amount_cents: amount, currency: "USD",
                created_at: created, updated_at: created }
        row.merge(seq: insert(:charges, row))
      end

      def next_behavior
        return @forced.shift unless @forced.empty?

        u = @rng.rand
        if u < 0.70 then :on_time
        elsif u < 0.85 then :"late_#{LATE_DAYS[@rng.rand(LATE_DAYS.size)]}"
        elsif u < 0.93 then @rng.rand < 0.5 ? :partial_completed : :partial_never
        elsif u < 0.96 then @rng.rand < 0.5 ? :nsf_repaid : :nsf_unpaid
        else :unpaid
        end
      end

      def play_behavior(lease, charge)
        rent = charge[:amount_cents]
        due = charge[:due_date]
        case (behavior = next_behavior)
        when :on_time then pay(lease, [[charge, rent]], due - @rng.rand(0..2))
        when :unpaid then nil
        when :partial_completed
          half = (rent / 2.0).round
          pay(lease, [[charge, half]], due)
          pay(lease, [[charge, rent - half]], due + 10)
        when :partial_never then pay(lease, [[charge, (rent / 2.0).round]], due)
        when :partial_nsf then reverse(pay(lease, [[charge, (rent / 2.0).round]], due), due + 5)
        when :nsf_repaid, :nsf_unpaid
          reversed = reverse(pay(lease, [[charge, rent]], due), due + 5)
          pay(lease, [[charge, rent]], due + 13) if reversed && behavior == :nsf_repaid
        else late(lease, charge, behavior.to_s.delete_prefix("late_").to_i)
        end
      end

      def late(lease, charge, base_days)
        days = base_days == 20 ? 20 + @rng.rand(0..9) : base_days
        paid_on = charge[:due_date] + days
        return if Time.utc(paid_on.year, paid_on.month, paid_on.day) > @end_of_anchor

        parts = [[charge, charge[:amount_cents]]]
        if days > lease[:grace_days]
          fee_due = charge[:due_date] + lease[:grace_days] + 1
          fee_created = Time.utc(fee_due.year, fee_due.month, fee_due.day, 6)
          parts << [create_charge(lease, kind: "late_fee", period: charge[:period], due: fee_due,
                                         amount: lease[:late_fee_cents], created: fee_created),
                    lease[:late_fee_cents]]
        end
        pay(lease, parts, paid_on)
      end

      # parts: [[charge_row, cents], ...]. Returns the payment row, or nil if it would
      # land after the anchor date.
      def pay(lease, parts, on_date)
        received = at(on_date)
        return nil if received > @end_of_anchor

        amount = parts.sum { |_, cents| cents }
        row = { id: id("pay"), operator_seq: lease[:operator_seq], lease_seq: lease[:seq], amount_cents: amount,
                currency: "USD", received_at: received, method: METHODS[@rng.rand(METHODS.size)],
                status: "settled", created_at: received, updated_at: received }
        row[:seq] = insert(:payments, row)
        parts.each do |charge, cents|
          insert(:payment_applications, payment_seq: row[:seq], charge_seq: charge[:seq], amount_cents: cents)
        end
        row
      end

      # The events this history would have produced (research R5), with historical
      # occurred_at and no deliveries; they can be replayed later (FR-029).
      def create_seed_events
        Presenters.eager(:payment, Payment.order(:seq)).all.each do |payment|
          created = Presenters.payment(payment).merge(status: "settled", reversal: nil,
                                                      updated_at: Presenters.time(payment.created_at))
          seed_event("payment.created", payment.operator_seq, created, payment.received_at)
          next unless payment.reversal

          seed_event("payment.reversed", payment.operator_seq, Presenters.payment(payment),
                     payment.reversal.reversed_at)
        end
        Presenters.eager(:lease, Lease.where(status: "ended_early").order(:seq)).all.each do |lease|
          at = Time.utc(lease.actual_end_date.year, lease.actual_end_date.month, lease.actual_end_date.day, 17)
          seed_event("lease.updated", lease.operator_seq, Presenters.lease(lease), at)
          seed_event("tenant.moved_out", lease.operator_seq,
                     { tenant: Presenters.tenant(lease.tenant), lease: Presenters.lease(lease),
                       move_out_date: lease.actual_end_date.iso8601 }, at)
        end
      end

      def seed_event(type, operator_seq, payload, occurred_at)
        insert(:events, id: id("evt"), operator_seq: operator_seq, type: type, occurred_at: occurred_at,
                        payload: Sequel.pg_jsonb_wrap(JSON.parse(JSON.generate(payload))),
                        correlation_id: "seed:#{@seed}", source: "seed", created_at: occurred_at)
      end

      def reverse(payment, on_date)
        return nil unless payment

        reversed_at = at(on_date)
        return nil if reversed_at > @end_of_anchor

        insert(:reversals, id: id("rev"), payment_seq: payment[:seq], reason: "nsf", reversed_at: reversed_at,
                           amount_cents: payment[:amount_cents], created_at: reversed_at, updated_at: reversed_at)
        @db[:payments].where(seq: payment[:seq]).update(status: "reversed", updated_at: reversed_at)
        payment
      end
    end
  end
end
