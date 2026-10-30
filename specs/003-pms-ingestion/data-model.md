# Data Model: PMS Connection and Webhook Ingestion

RentSync's own database, `rentsync_<deployment>` (research R13). Sequel migrations in
`api/db/migrations/`, expand-only (002 research R9). Times are `timestamptz`, UTC. IDs are
`bigint` identity columns internally, with prefixed random public IDs (`con_…`) where they
appear in URLs. Columns marked **enc** hold research R8's AES-GCM envelope.

## operators

A RentSync user representing a property management company (spec, Key Entities).

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| public_id | text unique | `opr_` + 20 base32 chars |
| email | text | synthetic, seeded; unique index on `lower(email)` |
| name | text | |
| password_digest | text | bcrypt (R11) |
| created_at | timestamptz | |

Seeded, one per mock PMS operator. No sign-up (FR-001).

## sessions

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| operator_id | FK operators | |
| token_sha256 | bytea unique | SHA-256 of the cookie token; the token itself is never stored |
| csrf_secret | bytea | random per session |
| created_at, last_seen_at | timestamptz | idle expiry 12 h, absolute 7 days (R11) |
| revoked_at | timestamptz null | set on sign-out |

## pms_clients

RentSync's registration with one PMS (research R9). One row per PMS per deployment.

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| pms_key | text unique | `mock_pms` (the only PMS, spec assumption) |
| base_url | text | PMS public URL |
| client_id | text | |
| client_secret | text **enc** | |
| signing_secret | text **enc** | webhook HMAC key |
| registered_at | timestamptz | |
| superseded_at | timestamptz null | set when re-registration replaces this row |

Exactly one row per `pms_key` has `superseded_at IS NULL` (partial unique index).

## connection_attempts

One try at connecting (research R7). Short-lived.

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| operator_id | FK operators | |
| state_sha256 | bytea unique | |
| code_verifier | text **enc** | PKCE |
| created_at | timestamptz | the purge's age |
| expires_at | timestamptz | created + 10 min |
| used_at | timestamptz null | single use: `UPDATE … WHERE used_at IS NULL` |
| outcome | text null | `connected`, `denied`, `failed`, `expired` |
| error_code | text null | e.g. `access_denied`, `invalid_grant`, `pms_operator_taken` |

Purged after 7 days.

## pms_connections

Links one RentSync operator to one PMS operator (spec, Key Entities).

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| public_id | text unique | `con_…` |
| operator_id | FK operators | |
| pms_client_id | FK pms_clients | |
| pms_operator_id | text | from the token response (R7) |
| pms_operator_name | text | |
| status | text | see state machine |
| access_token | text **enc** null | null after disconnect |
| refresh_token | text **enc** null | null after disconnect |
| access_expires_at | timestamptz null | |
| renewal_lease_until | timestamptz null | at most one renewal at a time (FR-005) |
| renewal_failures | int | consecutive temporary failures |
| last_renewal_error | text null | a code, never a token or body |
| connected_at, disconnected_at | timestamptz | |
| reconcile_watermark | timestamptz null | null until the first full run (R5) |
| reconcile_cursor | text null | resume point within a run |
| next_reconcile_at | timestamptz | |
| reconcile_lease_until | timestamptz null | claim (R2) |
| reconcile_failures | int | for backoff |
| reconcile_requested_at | timestamptz null | when the operator pressed **Reconcile now** (FR-020): the run is named `manual`, and a press during a run makes the next run due at once (added in migration 004) |

**Constraints**:

- unique `(pms_client_id, pms_operator_id)`: a PMS operator belongs to one RentSync operator,
  and reconnecting reuses the row (FR-008);
- unique `(operator_id, pms_client_id)`;
- check: `status IN ('active','renewal_failing','needs_reauth','disconnected')`.

**State machine**:

```text
            connect / reconnect
   (none) ────────────────────────► active ◄──────────────┐
                                     │  ▲                  │ renewal succeeds
             temporary renewal error │  │ renewal succeeds │
                                     ▼  │                  │
                              renewal_failing ─────────────┘
   active / renewal_failing ── invalid_grant, invalid_client, client re-registered ──► needs_reauth
   any ── operator disconnects ──► disconnected   (tokens set to null; events kept)
   needs_reauth / disconnected ── reconnect ──► active
```

Only `active` and `renewal_failing` connections are reconciled and accept webhooks.

**Renewal** (FR-004, FR-005): a caller needing a token when `access_expires_at < now + 60 s`
claims `renewal_lease_until` with a conditional `UPDATE … WHERE renewal_lease_until IS NULL OR
renewal_lease_until < now() RETURNING …`, calls `/oauth/token`, writes the new pair and clears the
lease in one statement. A caller that loses the claim waits up to 5 s for the winner and rereads
the row. Known residual risk: if the process dies after the PMS rotated the refresh token but
before the write, the connection needs reauthorization; plan.md records it.

## raw_events

One PMS fact exactly as received. **Immutable**: no `UPDATE` or `DELETE` is ever issued
(Constitution I); the application's database role is the only writer and the code has no update
path. A trigger raises on `UPDATE`/`DELETE` as a backstop.

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| pms_client_id | FK pms_clients | |
| connection_id | FK pms_connections | |
| event_id | text | PMS event ID, or `recon:<type>:<pay_id>` (R4) |
| business_key | text null | `payment.created:<pay_id>` / `payment.reversed:<pay_id>`; null for lease events |
| event_type | text | `payment.created`, `payment.reversed`, `lease.updated`, `tenant.moved_out` |
| occurred_at | timestamptz | from the envelope, or R4's rule for reconciled facts |
| received_at | timestamptz | arrival time |
| arrival_path | text | `webhook` or `reconciliation` |
| payload_raw | bytea | the exact bytes received (webhook) or the canonical JSON bytes (reconciliation); this is the record FR-013 keeps |
| payload | jsonb | `payload_raw` parsed, for querying; `jsonb` reorders keys, so it is never the source of truth |
| payload_sha256 | bytea | SHA-256 of `payload_raw` |
| correlation_id | text | R16 |
| reconciliation_run_id | FK null | set for reconciled facts |

**Constraints**: unique `(pms_client_id, event_id)` (FR-010); partial unique
`(pms_client_id, business_key) WHERE business_key IS NOT NULL` (FR-016).

**Index**: `(connection_id, received_at)`; `(connection_id, occurred_at)` for the ledger.

Payloads contain tenant personal data. They are never logged; health views show only type,
time and IDs.

## webhook_receipts

One row per delivery received, whatever its outcome (research R10, FR-012).

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| received_at | timestamptz | |
| pms_client_id | FK null | null if the signature could not be checked against any client |
| connection_id | FK null | when the operator resolved to one |
| operator_id | FK null | denormalized for scoping rejections that have no connection |
| delivery_id | text null | `PMS-Delivery-Id` |
| delivery_attempt | int null | `PMS-Delivery-Attempt` |
| event_id | text null | from the header, or the body once verified |
| event_type | text null | |
| outcome | text | `recorded`, `duplicate`, `rejected` |
| reason | text null | required when `rejected`: `missing_signature`, `bad_signature`, `stale_timestamp`, `body_too_large`, `malformed_body`, `unknown_operator`, `no_active_connection`, `conflicting_duplicate`, or `internal_error` (a `500`: the failed transaction rolled back, so this receipt is written on its own, best effort) |
| duplicate_of_path | text null | for `duplicate`: `webhook` or `reconciliation` |
| raw_event_id | FK null | the recorded or matched raw event |
| body_bytes | int | |
| body_sha256 | bytea | the body itself is never stored for rejections |
| correlation_id | text | |

**Index**: `(connection_id, received_at)`, `(operator_id, outcome, received_at)`.
**Retention**: deleted after 90 days by the daily purge (spec assumption). Raw events they point
to are unaffected.

Rejections with `unknown_operator` have no RentSync operator, so they appear only in telemetry
and the admin view, not on any operator's health page.

## reconciliation_runs

| Column | Type | Rules |
|---|---|---|
| id | bigint PK | |
| connection_id | FK | |
| trigger | text | `schedule`, `manual`, `initial` |
| started_at, finished_at | timestamptz | |
| outcome | text null | `succeeded`, `failed`, null while running |
| window_from | timestamptz null | null for a full backfill |
| pages, payments_seen, facts_added | int | |
| rate_limit_waits, rate_limit_wait_s | int, numeric | |
| error_code | text null | |
| correlation_id | text | |

A run interrupted by a crash stays with `outcome` null; the next claimant marks it `failed`
(`error_code = interrupted`) and starts a new run from the saved cursor.

## maintenance_leases

| Column | Type | Rules |
|---|---|---|
| name | text PK | `daily_purge` |
| lease_until | timestamptz | |
| last_run_at | timestamptz | |

## worker_heartbeats

Adapted from the mock's (001 data-model); `/healthz` reports the newest beat's age.

| Column | Type | Rules |
|---|---|---|
| worker_id | text PK | hostname and PID |
| beat_at | timestamptz | updated every 5 s by `bin/worker` |

## Requirement traceability

| Requirement | Where |
|---|---|
| FR-001, FR-023 | operators, sessions; every query scoped by `operator_id` |
| FR-002 | connection_attempts (state digest, PKCE, single use) |
| FR-003 | **enc** columns |
| FR-004–FR-006 | pms_connections renewal columns and state machine |
| FR-007, FR-008 | state machine; unique keys on pms_connections |
| FR-009–FR-014 | raw_events, webhook_receipts |
| FR-015–FR-020 | reconciliation columns, reconciliation_runs |
| FR-021, FR-022 | aggregates over raw_events, webhook_receipts, reconciliation_runs |
