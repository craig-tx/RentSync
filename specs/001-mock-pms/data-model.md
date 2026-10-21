# Data Model: Mock Property Management System (PMS)

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Research**: [research.md](research.md)

All tables live in the dedicated `mock_pms` database (research R2).

**Conventions**:

- `seq`: a `bigint` identity column. It is the internal primary key and the pagination key
  (R9), and it is never exposed except inside cursors.
- `id`: the public, prefixed identifier, for example `pay_7Q3K...`. It is unique and immutable.
  Seeded rows draw it from the seed RNG; all other rows use a random ID (research R5, R9).
- `created_at` and `updated_at`: `timestamptz` columns, set by the application and kept in UTC.
  Seeded rows take these values from the simulated history anchored on `SEED_ANCHOR_DATE`, not
  from the wall clock (R5).
- Money: `amount_cents` is an `integer` (it can be negative only on adjustments), alongside
  `currency char(3)` with the default `'USD'` (FR-010).
- Every foreign key is `NOT NULL` unless stated otherwise.

---

## Business data (seeded, read through `/v1`)

### operators

| Column | Type | Rules |
|---|---|---|
| seq | bigint PK | |
| id | text | unique, `op_` prefix |
| name | text | required |
| login | text | unique, used on the approval page |
| password_digest | text | bcrypt (R4) |
| timezone | text | IANA name, default `America/Chicago` |
| created_at, updated_at | timestamptz | |

### properties

| Column | Type | Rules |
|---|---|---|
| seq, id | | `prop_` prefix |
| operator_seq | FK → operators | indexed |
| address_line1, city, state, postal_code | text | synthetic |
| bedrooms, bathrooms | smallint / numeric(3,1) | |
| status | text | one of `occupied`, `vacant`, `make_ready` |
| created_at, updated_at | timestamptz | |

### tenants

| Column | Type | Rules |
|---|---|---|
| seq, id | | `ten_` prefix |
| operator_seq | FK → operators | indexed |
| first_name, last_name, email, phone | text | synthetic. Personal data, redacted in logs (FR-031) |
| status | text | `current` or `former` |
| created_at, updated_at | timestamptz | |

### leases

| Column | Type | Rules |
|---|---|---|
| seq, id | | `lease_` prefix |
| operator_seq | FK → operators | denormalized for scoping; must equal the property's operator |
| property_seq | FK → properties | |
| tenant_seq | FK → tenants | primary leaseholder |
| start_date | date | |
| scheduled_end_date | date | must be later than `start_date` |
| actual_end_date | date, nullable | set on move-out; must be on or before `scheduled_end_date` |
| monthly_rent_cents | integer | greater than 0 |
| currency | char(3) | default `'USD'`. Applies to `monthly_rent_cents` and `late_fee_cents` (FR-010) |
| due_day | smallint | 1–28 |
| grace_days | smallint | default 3 |
| late_fee_cents | integer | default 7500 |
| status | text | see state machine below |
| created_at, updated_at | timestamptz | |

**Lease states**:

```
          start_date reached         move-out (scenario/seed)
pending ─────────────────────► active ─────────────────────► ended_early
                                  │
                                  │ scheduled_end_date passed
                                  └──────────────────────────► ended
```

- At most one lease per property may be `active` at a time.
- When a lease becomes `ended_early`:
  - `actual_end_date` is set,
  - the tenant's status changes to `former`,
  - no further rent charges are generated for the lease,
  - `lease.updated` and `tenant.moved_out` events are emitted (FR-015).

### charges

| Column | Type | Rules |
|---|---|---|
| seq, id | | `chg_` prefix |
| operator_seq, lease_seq | FKs | |
| kind | text | `rent` or `late_fee` |
| period | date | first day of the month the charge covers |
| due_date | date | |
| amount_cents | integer | greater than 0 |
| created_at, updated_at | timestamptz | |

- There is a unique constraint on `(lease_seq, kind, period)`, so a lease gets at most one rent
  charge per month.
- No charge may have a `period` later than the lease's `actual_end_date`.

### payments

| Column | Type | Rules |
|---|---|---|
| seq, id | | `pay_` prefix |
| operator_seq, lease_seq | FKs | |
| amount_cents | integer | greater than 0 |
| received_at | timestamptz | |
| method | text | `ach`, `card`, `check`, or `money_order` |
| status | text | `settled` or `reversed` |
| created_at, updated_at | timestamptz | |

**Payment states**: `settled` → `reversed`. The transition happens once, through a
`reversals` row, and is never undone.

### payment_applications

This table records how the PMS reports each payment as applied. RentSync does not treat it as
authoritative (see the spec Assumptions).

| Column | Type | Rules |
|---|---|---|
| payment_seq | FK → payments | |
| charge_seq | FK → charges | |
| amount_cents | integer | greater than 0 |
| | | primary key `(payment_seq, charge_seq)` |

- The amounts applied for a payment must not add up to more than the payment.
- The amounts applied to a charge by **settled** payments must not add up to more than the charge. A reversed payment keeps its PMS-reported application, so a repaid NSF month has two applications on one charge.

### reversals

| Column | Type | Rules |
|---|---|---|
| seq, id | | `rev_` prefix |
| payment_seq | FK → payments | **unique**, so a payment can be reversed at most once |
| reason | text | `nsf`, `account_closed`, or `stop_payment` |
| reversed_at | timestamptz | must be later than the payment's `received_at` |
| amount_cents | integer | must equal the payment's full amount (spec edge case) |
| created_at, updated_at | timestamptz | FR-010 applies to every record |

---

## OAuth

### clients

| Column | Type | Rules |
|---|---|---|
| seq, id | | `client_` prefix (this is the public `client_id`) |
| name | text | |
| secret_digest | text | SHA-256 of the client secret (R4). The plaintext is shown once at registration |
| redirect_uris | text[] | at least one; redirects must match an entry exactly |
| subscriber_url | text, nullable | webhook target (FR-001) |
| signing_secret | text | stored as given (R4), shown at registration and in admin |
| rate_limit_per_minute | integer, nullable | overrides the global default (FR-021) |
| created_at, updated_at | timestamptz | |

### grants

| Column | Type | Rules |
|---|---|---|
| seq, id | | `grant_` prefix |
| client_seq, operator_seq | FKs | |
| scope | text | always `read` (spec Assumptions) |
| created_at | timestamptz | |
| revoked_at | timestamptz, nullable | when set, every token in the grant is invalid (FR-007) |

- A partial unique index on `(client_seq, operator_seq) WHERE revoked_at IS NULL` allows at
  most one active grant for each client and operator.
- If the same operator approves the same client again, the existing active grant is reused.

### authorization_codes

| Column | Type | Rules |
|---|---|---|
| code_digest | text PK | SHA-256 |
| grant_seq | FK | |
| redirect_uri | text | must match exactly when the code is exchanged |
| code_challenge, code_challenge_method | text, nullable | PKCE S256 (R3) |
| expires_at | timestamptz | issue time + 60 s |
| used_at | timestamptz, nullable | set during the exchange, in the same transaction as token issuance |

A code is single-use (Constitution II): the exchange runs
`UPDATE ... SET used_at = now() WHERE code_digest = ? AND used_at IS NULL`. If that changes
zero rows, the request gets `invalid_grant`.

### access_tokens / refresh_tokens

| Column | Type | Rules |
|---|---|---|
| token_digest | text PK | SHA-256 |
| grant_seq | FK | |
| expires_at | timestamptz | access: issue time + `ACCESS_TOKEN_TTL` (300 s). Refresh: issue time + 30 days |
| used_at | timestamptz, nullable | **refresh tokens only**, rotated with the same single-use update as authorization codes |
| created_at | timestamptz | |

**Token validation order** (FR-006):

1. Unknown digest → `invalid`.
2. Grant revoked → `invalid`.
3. Past `expires_at` → `expired`.
4. Otherwise valid.

---

## Events and delivery

### events (immutable)

| Column | Type | Rules |
|---|---|---|
| seq, id | | `evt_` prefix. **This is the idempotency key that receivers deduplicate on** |
| operator_seq | FK | |
| type | text | `payment.created`, `payment.reversed`, `lease.updated`, or `tenant.moved_out` |
| occurred_at | timestamptz | when the business change happened (historical for seeded events) |
| payload | jsonb | snapshot of the resource, shaped like its `/v1` representation |
| correlation_id | text | from the request or scenario run that caused the event (R10) |
| source | text | `seed`, `scenario:<name>`, or `admin` |
| created_at | timestamptz | |

- Events are never updated or deleted.
- An event is created in the same transaction as the business change it describes.

### deliveries

| Column | Type | Rules |
|---|---|---|
| seq, id | | `dlv_` prefix |
| event_seq, client_seq | FKs | |
| scheduled_at | timestamptz | the time the delivery is next due |
| status | text | see the state machine below |
| attempt_count | smallint | |
| replay | boolean | default false (FR-029) |
| chaos | jsonb | the decision made at creation time (R7), for example `{"delayed_s":12}`, `{"reorder_hold_s":4}`, `{"malform":"truncate"}`, or `{"duplicate_of":"dlv_..."}`. `{}` means no chaos |
| created_at, updated_at | timestamptz | |

- There is an index on `(status, scheduled_at)` to serve the worker's claim query.

**Delivery states**:

```
pending ──claim──► in_flight ──2xx──► succeeded
   ▲                   │
   └──fail, attempts < MAX─┘
                       └──fail, attempts = MAX──► exhausted
```

A delivery left in `in_flight` for more than 60 seconds is assumed to belong to a crashed
worker. It goes back to `pending`, so delivery is at-least-once (R6).

### delivery_attempts (immutable, the delivery log for FR-020)

| Column | Type | Rules |
|---|---|---|
| seq | bigint PK | |
| delivery_seq | FK | |
| attempt_number | smallint | unique together with `delivery_seq` |
| started_at, finished_at | timestamptz | |
| outcome | text | `success`, `http_error`, `timeout`, or `connection_error` |
| http_status | smallint, nullable | |
| chaos_applied | jsonb | copied from the delivery |
| correlation_id | text | |

### Event fan-out rule (FR-017)

When an event is created, the system adds one `deliveries` row for each client that:

- has an active grant for the event's operator, and
- has a non-null `subscriber_url`.

Chaos may add one extra row per client (a duplicate). Clients without a `subscriber_url` get no
row, but the event is still recorded and can be replayed.

---

## Harness control

### chaos_settings (exactly one row)

| Column | Type | Rules |
|---|---|---|
| duplicate_rate, out_of_order_rate, delay_rate, server_error_rate, malformed_rate | numeric(4,3) | each between 0 and 1. **All default to 0** (FR-024) |
| delay_min_s, delay_max_s | integer | 0 ≤ min ≤ max ≤ 3600. Defaults 5 and 60 |
| seed | bigint | default 1 (R7) |
| updated_at | timestamptz | |

### chaos_counters (one row per stream)

| Column | Type | Rules |
|---|---|---|
| stream | text PK | `delivery` or `api`; both rows are seeded |
| value | bigint | default 0. Each chaos decision on a stream increments that stream's row inside the caller's transaction. Both rows are reset to 0 by `PUT /admin/chaos` and by a reset (R7). Separate rows mean an API draw never waits on a delivery transaction |

### seed_runs

| Column | Type | Rules |
|---|---|---|
| seq | bigint PK | |
| seed | bigint | |
| anchor_date | date | |
| data_digest | text | SHA-256 of the canonical dump defined in research R5. Excludes `seq`, `password_digest`, and all OAuth, delivery, and harness tables. Used to check SC-002 |
| ran_at | timestamptz | |

### admin_idempotency_keys

| Column | Type | Rules |
|---|---|---|
| key | text PK | taken from the `Idempotency-Key` header |
| request_digest | text | SHA-256 of the method, path, and body |
| response_status | smallint, nullable | null while in flight; a duplicate request then gets `409 idempotency_in_progress` |
| response_body | jsonb, nullable | null while in flight. MUST NOT contain secrets, so `POST /admin/clients` never uses this table (R11) |
| created_at | timestamptz | rows older than 24 h may be deleted |

This table is **kept across `/admin/reset`**, so a retried reset finds its own key and doesn't
reseed a second time.

### worker_heartbeats

| Column | Type | Rules |
|---|---|---|
| worker_id | text PK | |
| beat_at | timestamptz | updated every 5 s (R12) |

---

## Relationships

```
operators 1─* properties 1─* leases *─1 tenants
operators 1─* leases 1─* charges
          leases 1─* payments 1─0..1 reversals
          payments *─* charges   (via payment_applications)
clients 1─* grants *─1 operators
grants 1─* authorization_codes | access_tokens | refresh_tokens
operators 1─* events 1─* deliveries *─1 clients
deliveries 1─* delivery_attempts
```

## Requirement traceability

| Requirement | Enforced by |
|---|---|
| FR-005, FR-006, FR-007 | Single-use `used_at` updates; validation order; `grants.revoked_at` |
| FR-008, SC-009 | Every `/v1` query is scoped to `operator_seq` from the token's grant |
| FR-009 | Keyset on `seq` (R9) |
| FR-010 | `id`, `created_at`, `updated_at`, and `amount_cents` + `currency` on every business table |
| FR-012 | Lease and payment state machines; `reversals`; the seed profile (R5) |
| FR-013, SC-002 | `seed_runs.data_digest` |
| FR-016, FR-029 | Immutable `events`; a replay is a new `deliveries` row with `replay = true` |
| FR-020 | `delivery_attempts` |
| FR-023 – FR-026 | `chaos_settings`; `deliveries.chaos` decided at creation time |
