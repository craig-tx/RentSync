# frozen_string_literal: true

require "digest"

module MockPms
  module Seed
    # SHA-256 of a canonical JSON dump of the /v1-visible business data (research R5):
    # rows ordered by public id, keys sorted, UTC timestamps at second precision.
    # Excludes seq, password_digest and every OAuth, delivery and harness table.
    module Digest
      module_function

      def compute = ::Digest::SHA256.hexdigest(canonical_dump)

      def canonical_dump
        JSON.generate(deep_sort(sections))
      end

      def sections
        {
          operators: Operator.order(:id).map { |o| Presenters.operator(o) },
          properties: Property.order(:id).map { |p| Presenters.property(p) },
          tenants: Tenant.order(:id).map { |t| Presenters.tenant(t) },
          leases: Presenters.eager(:lease, Lease.order(:id)).all.map { |l| Presenters.lease(l) },
          charges: Presenters.eager(:charge, Charge.order(:id)).all.map { |c| Presenters.charge(c) },
          payments: Presenters.eager(:payment, Payment.order(:id)).all.map { |p| Presenters.payment(p) }
        }.merge(extra_sections)
      end

      # Seeded events are part of the reproducible seed state (T068).
      def extra_sections
        return {} unless MockPms.db.table_exists?(:events)

        events = Event.order(:id).eager(:operator).all.map do |e|
          Events::Serializer.envelope(e).merge(source: e.source, correlation_id: e.correlation_id)
        end
        { events: events }
      end

      def deep_sort(value)
        case value
        when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [k.to_s, deep_sort(v)] }
        when Array then value.map { |v| deep_sort(v) }
        else value
        end
      end
    end

    # Truncates seed, OAuth, event and delivery state, regenerates, and records a
    # seed_runs row. Keeps admin_idempotency_keys and seed_runs (research R11).
    module Reset
      KEEP = %i[schema_migrations schema_info admin_idempotency_keys seed_runs chaos_settings chaos_counters].freeze

      module_function

      def run!(seed:, anchor_date:)
        db = MockPms.db
        db.transaction do
          tables = db.tables - KEEP
          db.run("TRUNCATE #{tables.map { |t| db.literal(t) }.join(', ')} RESTART IDENTITY CASCADE")
          db[:chaos_counters].update(value: 0) if db.table_exists?(:chaos_counters)
          Generator.run(seed: seed, anchor_date: anchor_date)
          digest = Digest.compute
          db[:seed_runs].insert(seed: seed, anchor_date: anchor_date, data_digest: digest, ran_at: Clock.now)
          { seed: seed, anchor_date: anchor_date.iso8601, data_digest: digest }
        end
      end
    end

    # Derives the payment-behavior mix from the data itself (used by T033 and
    # bin/seed_report), so it works on any database, not just a fresh seed.
    module Report
      module_function

      def behaviors(anchor: nil)
        stats = { on_time: 0, late_days: [], partial_completed: 0, partial_never_completed: 0, nsf_reversed: 0,
                  unpaid: 0 }
        charges = Charge.where(kind: "rent")
        charges = charges.where { due_date <= anchor } if anchor
        by_charge = MockPms.db[:payment_applications].join(:payments, seq: :payment_seq)
                           .select(Sequel[:payment_applications][:charge_seq],
                                   Sequel[:payment_applications][:amount_cents].as(:applied),
                                   Sequel[:payments][:status], Sequel[:payments][:received_at])
                           .all.group_by { |r| r[:charge_seq] }
        charges.each { |c| classify(stats, c, by_charge.fetch(c.seq, [])) }
        stats[:late_days] = stats[:late_days].uniq.sort
        stats
      end

      def classify(stats, charge, rows)
        settled = rows.select { |r| r[:status] == "settled" }
        paid = settled.sum { |r| r[:applied] }
        if rows.any? { |r| r[:status] == "reversed" }
          stats[:nsf_reversed] += 1
        elsif rows.empty?
          stats[:unpaid] += 1
        elsif settled.size > 1 && paid >= charge.amount_cents
          stats[:partial_completed] += 1
        elsif paid < charge.amount_cents
          stats[:partial_never_completed] += 1
        else
          days = (settled.first[:received_at].to_date - charge.due_date).to_i
          days <= 0 ? stats[:on_time] += 1 : stats[:late_days] << days
        end
      end

      def counts_by_operator
        Operator.order(:seq).map do |op|
          { login: op.login, password: "#{op.login}-pass", name: op.name,
            properties: Property.where(operator_seq: op.seq).count,
            leases: Lease.where(operator_seq: op.seq).count,
            tenants: Tenant.where(operator_seq: op.seq).count }
        end
      end
    end
  end
end
