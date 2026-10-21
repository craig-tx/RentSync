# frozen_string_literal: true

require "bcrypt"

# Minimal, explicit test data. Seeded data is exercised by the seed specs.
module Factory
  module_function

  def seq = @seq = (@seq || 0) + 1

  def operator(login: "op#{seq}", name: "Operator #{login}")
    MockPms::Operator.create(name: name, login: login,
                             password_digest: BCrypt::Password.create("#{login}-pass", cost: BCrypt::Engine::MIN_COST))
  end

  def property(operator, status: "occupied")
    MockPms::Property.create(operator_seq: operator.seq, address_line1: "#{seq} Elm St", city: "Austin",
                             state: "TX", postal_code: "78701", bedrooms: 3, bathrooms: 2.0, status: status)
  end

  def tenant(operator, status: "current")
    MockPms::Tenant.create(operator_seq: operator.seq, first_name: "Test#{seq}", last_name: "Tenant",
                           email: "t#{seq}@example.test", phone: "555-0100", status: status)
  end

  def lease(operator, property: nil, tenant: nil, status: "active", start_date: Date.new(2026, 1, 1))
    property ||= self.property(operator)
    tenant ||= self.tenant(operator)
    MockPms::Lease.create(operator_seq: operator.seq, property_seq: property.seq, tenant_seq: tenant.seq,
                          start_date: start_date, scheduled_end_date: start_date.next_year - 1,
                          monthly_rent_cents: 150_000, due_day: 1, status: status)
  end

  def charge(lease, period: Date.new(2026, 2, 1), kind: "rent", amount_cents: 150_000)
    MockPms::Charge.create(operator_seq: lease.operator_seq, lease_seq: lease.seq, kind: kind, period: period,
                           due_date: period, amount_cents: amount_cents)
  end

  def payment(lease, amount_cents: 150_000, received_at: Time.utc(2026, 2, 1, 10), status: "settled")
    MockPms::Payment.create(operator_seq: lease.operator_seq, lease_seq: lease.seq, amount_cents: amount_cents,
                            received_at: received_at, method: "ach", status: status)
  end

  def client(name: "client #{seq}", redirect_uris: ["http://localhost:9999/cb"], subscriber_url: nil,
             rate_limit_per_minute: nil)
    MockPms::Clients.register!(name: name, redirect_uris: redirect_uris, subscriber_url: subscriber_url,
                               rate_limit_per_minute: rate_limit_per_minute)
  end

  # Returns [grant, token_set] for an operator/client pair, via the real OAuth flow.
  def tokens(client, operator, redirect_uri: client.redirect_uris.first)
    code = MockPms::OAuth::Service.approve!(client: client, operator: operator, redirect_uri: redirect_uri)
    set = MockPms::OAuth::Service.exchange_code!(client: client, code: code, redirect_uri: redirect_uri)
    [MockPms::Grant.active.first(client_seq: client.seq, operator_seq: operator.seq), set]
  end
end
