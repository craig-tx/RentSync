# frozen_string_literal: true

module MockPms
  # Turn models into the exact /v1 JSON shapes in contracts/openapi.yaml. Public ids
  # only, never seq. Webhook payloads and the seed digest reuse these shapes.
  module Presenters
    module_function

    def time(value) = value&.utc&.iso8601
    def date(value) = value&.iso8601
    def money(cents, currency = "USD") = { amount_cents: cents, currency: currency.to_s.strip }

    def stamps(row) = { created_at: time(row.created_at), updated_at: time(row.updated_at) }

    def operator(o)
      { id: o.id, name: o.name, login: o.login, timezone: o.timezone }.merge(stamps(o))
    end

    def property(p)
      {
        id: p.id,
        address: { line1: p.address_line1, city: p.city, state: p.state, postal_code: p.postal_code },
        bedrooms: p.bedrooms, bathrooms: p.bathrooms&.to_f, status: p.status
      }.merge(stamps(p))
    end

    def tenant(t)
      { id: t.id, first_name: t.first_name, last_name: t.last_name, email: t.email, phone: t.phone,
        status: t.status }.merge(stamps(t))
    end

    def lease(l)
      {
        id: l.id, property_id: l.property.id, tenant_id: l.tenant.id,
        start_date: date(l.start_date), scheduled_end_date: date(l.scheduled_end_date),
        actual_end_date: date(l.actual_end_date),
        monthly_rent: money(l.monthly_rent_cents, l.currency), due_day: l.due_day, grace_days: l.grace_days,
        late_fee: money(l.late_fee_cents, l.currency), status: l.status
      }.merge(stamps(l))
    end

    def charge(c)
      { id: c.id, lease_id: c.lease.id, kind: c.kind, period: date(c.period), due_date: date(c.due_date) }
        .merge(money(c.amount_cents, c.currency)).merge(stamps(c))
    end

    def payment(p)
      applied = p.applications.map { |a| { charge_id: a.charge.id, amount_cents: a.amount_cents } }
                 .sort_by { |a| a[:charge_id] }
      {
        id: p.id, lease_id: p.lease.id, received_at: time(p.received_at), method: p[:method], status: p.status,
        applied_to: applied, reversal: reversal(p.reversal)
      }.merge(money(p.amount_cents, p.currency)).merge(stamps(p))
    end

    def reversal(r)
      return nil unless r

      { id: r.id, reason: r.reason, reversed_at: time(r.reversed_at), amount_cents: r.amount_cents }
    end

    # Datasets with the associations each presenter needs, to avoid N+1 queries.
    def eager(resource, dataset)
      case resource
      when :lease then dataset.eager(:property, :tenant)
      when :charge then dataset.eager(:lease)
      when :payment then dataset.eager(:lease, :reversal, applications: :charge)
      else dataset
      end
    end
  end
end
