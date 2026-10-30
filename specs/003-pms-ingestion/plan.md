# Implementation Plan: PMS Connection and Webhook Ingestion

**Branch**: `003-pms-ingestion` | **Date**: 2026-10-28 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-pms-ingestion/spec.md`

**Note**: the tech stack comes from the kickoff's plan prompt (`rentsync-speckit-kickoff.md`
§3), with its infrastructure line replaced by feature 002's deployment, as the operator
directed.

## Summary

Build `/api`, RentSync's first service. Operators sign in with seeded RentSync accounts and
connect their mock PMS account through OAuth (authorization code with PKCE). RentSync keeps the
PMS credentials encrypted with AES-256-GCM and renews them under a Postgres lease, so several
instances never race the PMS's single-use refresh tokens.

PMS webhooks arrive at a raw Rack endpoint that verifies the HMAC over the exact bytes before
parsing. Each event is recorded once under database unique keys: the PMS event ID, plus a
business key for payment facts, so a payment seen first by reconciliation is never counted
again when its webhook arrives. The PMS gets `200` only after the commit.

A worker claims due reconciliations from Postgres (`SKIP LOCKED` leases). It walks
`/v1/payments` with a saved cursor, through a Redis token bucket shared by all instances, and
honors `Retry-After`. Connection health is computed from durable receipt and run rows, so it
is exact across instances and restarts. The UI is three server-rendered pages, with JSON twins
for the later dashboard.

RentSync deploys next to the mock PMS on the existing 002 hosts, under its own hostname, and
the release pipeline ships both images as one unit. See [research.md](research.md) R1–R18.

## Technical Context

**Language/Version**: Ruby ≥ 3.3

**Primary Dependencies**: Grape and Puma on Rack, Sequel with `pg`, `bcrypt`, `redis`; the same
six runtime gems as the mock PMS, nothing new (R18). Stdlib: `openssl` (HMAC, AES-GCM),
`net/http`, `json`, `erb`, `securerandom`.

**Storage**: PostgreSQL 16, a new `rentsync_<deployment>` database on the existing Postgres
container. Redis 7 (database 1, `rentsync:` prefix) holds the PMS rate bucket, the shared
`blocked_until`, the sign-in throttle, and metric totals: short-lived data only.

**Testing**: RSpec and Rack::Test against real Postgres and Redis; a fake PMS Rack app for
client tests; an end-to-end signed-request spec; and a CI `ingestion-e2e` job running the real
mock with chaos (R17). RuboCop.

**Target Platform**: Linux containers. Docker Compose locally and in CI; on AWS, the 002 EC2
hosts (t4g.micro, arm64) through the existing release pipeline.

**Project Type**: Web service (API plus worker) with three server-rendered pages.

**Performance Goals**: webhook acknowledged within 2 s at p95 (SC-006); a full backfill of one
seeded operator within one rate-limit-respecting run (a few minutes); health figures current
within 1 minute (SC-008).

**Constraints**:

- Stateless processes (Constitution X).
- Ack only after commit.
- Signature checked before parsing.
- No tenant data or secrets in logs or telemetry.
- Fits beside the mock on a 1 GiB host; sizes up only on proven need (R14).
- Expand-only migrations.

**Scale/Scope**: 3 operators, about 1,500 historical payment facts, bursts of about 60 events.
A demo, not a product.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Status | Evidence |
|---|---|---|---|
| I | Correctness over cleverness | **PASS** | No ledger yet. Raw events are immutable: no update path, plus a trigger that raises on `UPDATE`/`DELETE` (data-model). A cross-path business key prevents double-counting a payment seen by both webhook and reconciliation (R4). A conflicting duplicate is recorded as a rejection, never silently overwritten |
| II | Idempotency everywhere | **PASS** | See [Idempotency keys](#idempotency-keys). Both inbound keys are database unique constraints. Reconciliation reruns are idempotent and resumable (R5) |
| III | Test-first for domain logic | **PASS (one deferral, tracked)** | The test-first units are listed in R17: signature, window, envelope, dedup decision, AES-GCM, PKCE/state, renewal lease, backoff, reconciliation window and cursor. The end-to-end spec runs from a signed HTTP request to the persisted raw event; "to the persisted ledger effect" cannot exist before the ledger, so it is a Complexity Tracking entry, extended by the ledger feature. CI stays the merge gate |
| IV | Integrations are hostile by default | **PASS** | Out-of-order events are recorded with occurrence and arrival times, and ordering is left to the ledger (FR-014). Malformed and unverifiable deliveries are rejected and recorded with a reason (R3, R10). `429` and `Retry-After` are honored through a shared block plus backoff with jitter (R6). Reconciliation is the second path (R5). Chaos-on coverage comes from the CI `ingestion-e2e` job and quickstart §3–§4 |
| V | AI agents propose, humans dispose | **N/A** | No agent in this feature |
| VI | Observable by default | **PASS** | Through the Collector bridge (ADR-0004), with no SDK. JSON logs carry `correlation_id`, taken from the PMS's `X-Correlation-Id` and stored on the raw event for the ledger to carry on (R16). `/healthz` and `/metrics` exist on both processes. Rejections, duplicates, renewals and runs are metrics. Resource attributes come from the existing Collector config. Telemetry redaction is in-process and again at the Collector |
| VII | Secure by default | **PASS** | HMAC is verified before any parsing, with constant-time comparison and a ±300 s window (R3). PMS tokens and client secrets use AES-256-GCM with per-row associated data (R8). Session tokens are stored as SHA-256 and passwords as bcrypt; CSRF tokens protect forms and sign-in is throttled (R11). Every query is scoped by the session's operator (FR-023). Rejected bodies are never stored. The new secrets go into SSM through the write-only pattern (ADR-0007) |
| VIII | Simplicity | **PASS** | No new gems (R18). Sidekiq and Next.js are **deferred, with reasons**: there is no async processing until the ledger, and a dashboard of three pages doesn't warrant a Node runtime on a 1 GiB host (R2, R12, ADR-0009, ADR-0010). Shared modules are copied rather than turned into a library (R1) |
| IX | Documented decisions | **PASS (follow-up)** | ADRs to write as tasks: see [ADRs to write](#adrs-to-write) |
| X | Stateless, horizontally scalable services | **PASS** | Durable state is in Postgres and short-lived state in Redis. Reconciliation is claimed with `SKIP LOCKED` leases; renewal uses a conditional-`UPDATE` lease; the daily purge uses a lease row (R2). The rate bucket and `blocked_until` live in Redis (R6). Health figures are SQL aggregates (R10). Process memory holds request data, configuration, and the metric delta buffer: a crash loses at most 5 s of metric deltas, as in 001 R12. Quickstart §4.5 checks this with two workers. No distributed lock is added beyond 001's migration advisory lock |
| — | Scope & data constraints | **PASS** | Synthetic data only: the operators are seeded to match the mock's synthetic operators. Not presented as production-ready; production-differences.md is extended |
| — | Workflow & quality gates | **PASS** | `/speckit-analyze` runs before `/speckit-implement`. CI gains `api` test and `ingestion-e2e` jobs. Build-log entries go in the PR's slot. The cross-platform rule covers the new scripts (bash 4.4+ or Ruby) |

**Gate result (pre-research)**: PASS, with two tracked exceptions (Complexity Tracking).

**Gate result (post-design)**: PASS. Re-checked against [data-model.md](data-model.md) and
[contracts/](contracts/).

- The design added a contract change to the mock PMS: `operator_id` in token responses,
  additive ([pms-changes.md](contracts/pms-changes.md)).
- It added a second ECR repository and three SSM secrets, all in the existing patterns
  ([host-changes.md](contracts/host-changes.md)).
- One residual risk is recorded rather than engineered away. If a process dies after the PMS
  rotated a refresh token but before RentSync stores the new one, that connection needs
  reauthorization. The mock invalidates used refresh tokens immediately, so only a PMS-side
  grace period could remove the risk. Health shows the state, and reconnecting keeps the
  history.

### Idempotency keys

| Key | Protects | Mechanism |
|---|---|---|
| `raw_events (pms_client_id, event_id)` | Recording a PMS event twice: retries, chaos duplicates, replays | Unique constraint; `ON CONFLICT DO NOTHING`, then compare `payload_sha256` |
| `raw_events (pms_client_id, business_key)` partial | Recording a payment or reversal twice across webhook and reconciliation | Partial unique constraint (R4) |
| Reconciliation synthetic `event_id` `recon:<type>:<pay_id>` | Reruns of reconciliation adding a fact twice | Deterministic, so the same unique constraint applies |
| `connection_attempts.state_sha256` + `used_at` | Replayed or forged OAuth callbacks | Unique, plus a single-use conditional `UPDATE` |
| `pms_connections (pms_client_id, pms_operator_id)` | Two connections for one PMS operator; a reconnect duplicating history | Unique; reconnect updates the row (FR-008) |
| `pms_connections.renewal_lease_until` | Two simultaneous renewals burning the single-use refresh token | Conditional `UPDATE` lease (FR-005) |
| `pms_connections.reconcile_lease_until` + `reconcile_cursor` | Concurrent or repeated runs per connection | `SKIP LOCKED` claim; cursor resume (FR-018, FR-019) |
| `pms_clients` one active per `pms_key` | Registering twice on concurrent `bin/setup` | An advisory lock around `ensure!` (one `POST` at a time), plus a partial unique index as a backstop (R9). A crash mid-registration can orphan one PMS client; see Complexity Tracking |

### Dependencies

No new gems: the API uses the same six runtime gems as the mock PMS (research R18).

| Gem | Purpose | Justification |
|---|---|---|
| `grape` | HTTP API | The project-standard API framework (kickoff §3) |
| `puma` | Rack server | The standard threaded server |
| `sequel` | Database access and migrations | The project-standard ORM |
| `pg` | Postgres driver | Sequel needs it for Postgres |
| `bcrypt` | Operator password hashing | A security-sensitive primitive with no stdlib equivalent |
| `redis` | Rate bucket, `blocked_until`, sign-in throttle, metric totals | The official client; `EVALSHA` and `MULTI` keep shared state atomic (Constitution X) |
| `rspec`, `rack-test`, `rubocop` *(dev)* | Tests and lint | Project standard |

Stdlib, no gem: `openssl` (HMAC, AES-256-GCM, digests), `net/http`, `json`, `erb`,
`securerandom`, `uri`.

### Configuration

`.env.example` gains every new setting with a safe local value: `RENTSYNC_DATABASE_URL`,
`RENTSYNC_REDIS_URL`, `RENTSYNC_ENCRYPTION_KEYS` (a clearly fake development key),
`RENTSYNC_OPERATOR_SEED_PASSWORD`, `RENTSYNC_SESSION_SECRET`, `MOCK_PMS_ADMIN_TOKEN` (locally
the mock's `ADMIN_TOKEN`, for registration, R9; RentSync's own `/admin` endpoints take the same
value, so no new secret), the four URL settings (research R13), `RECONCILE_INTERVAL_S`,
`RECONCILE_OVERLAP_S`, and the PMS bucket size. Hosts get the
same names from `rentsync-render-env` ([host-changes.md](contracts/host-changes.md)).

### ADRs to write

1. **ADR-0009: Postgres-claimed background work instead of Sidekiq (for now).** Context: the
   kickoff names Sidekiq. Decision: leases and `SKIP LOCKED` (R2). Revisit when the ledger
   needs a high-volume queue.
2. **ADR-0010: Server-rendered pages until the dashboard.** Defers Next.js and `/web` to the
   operator dashboard feature (R12).
3. **ADR-0011: Exactly-once raw events across two arrival paths.** Covers the two unique keys,
   synthetic reconciliation IDs, and acknowledging only after commit (R3, R4).
4. **ADR-0012: PMS credential encryption and registration.** Covers AES-256-GCM with
   associated data and the key list for rotation (R8), and the admin-API registration shortcut
   that works only because the PMS is our own mock (R9).

## Project Structure

### Documentation (this feature)

```text
specs/003-pms-ingestion/
├── plan.md
├── research.md            # R1–R18
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── openapi.yaml       # pages, JSON, admin, ops
│   ├── webhook-receiver.md
│   ├── pms-changes.md     # mock PMS token response gains operator_id
│   └── host-changes.md    # workspace variables, compose, Caddy, deploy, ECR
├── checklists/requirements.md
└── tasks.md               # /speckit-tasks
```

### Source Code (repository root)

```text
api/
├── Gemfile, Gemfile.lock, Dockerfile, config.ru
├── config/
│   ├── puma.rb
│   └── settings.rb             # ENV → typed config (intervals, windows, bucket, keys)
├── bin/
│   ├── setup                   # create DB, migrate, seed operators, PmsRegistration.ensure!
│   ├── worker                  # reconciliation claims, purge, heartbeat, metrics endpoint
│   ├── connect_operator        # headless OAuth approval driver (CI, quickstart)
│   ├── compare_with_pms        # SC-003 comparison
│   ├── send_test_webhook       # signed/unsigned/stale test deliveries
│   └── pms_client              # inspect or set PMS client credentials
├── db/migrations/
├── lib/rentsync/
│   ├── app.rb                  # Rack builder: webhook endpoint first, then Grape, pages
│   ├── db.rb, redis.rb, logging.rb, metrics/   # adapted copies of the mock's (R1)
│   ├── crypto/box.rb           # AES-256-GCM envelope (R8)
│   ├── auth/                   # passwords, sessions, csrf, sign-in throttle (R11)
│   ├── webhooks/
│   │   ├── receiver.rb         # Rack endpoint (R3)
│   │   ├── signature.rb
│   │   ├── envelope.rb
│   │   └── recorder.rb         # dedup decision + receipt (R4, R10)
│   ├── pms/
│   │   ├── client.rb           # Net::HTTP; bucket, blocked_until, backoff (R6)
│   │   ├── oauth.rb            # authorize URL, code exchange, renewal lease (R7)
│   │   ├── registration.rb     # ensure! (R9)
│   │   └── rate_limit/token_bucket.lua
│   ├── reconciliation/
│   │   ├── scheduler.rb        # SKIP LOCKED claims, backoff
│   │   └── run.rb              # window, cursor walk, fact insertion (R5)
│   ├── health/report.rb        # aggregates (R10)
│   ├── api/                    # Grape: /v1/connections*, /admin/*, /healthz, /metrics
│   └── web/                    # pages: sign-in, connections, health (ERB views + stylesheet)
└── spec/
    ├── fixtures/signature_vector.json   # copied from mock_pms
    ├── unit/  requests/  e2e/  support/fake_pms.rb

mock_pms/                       # token response gains operator_id/operator_name (pms-changes.md)
infra/
├── host/compose.env.yaml, Caddyfile.env, bin/rentsync-deploy, bin/rentsync-render-env (+ tests)
├── otel/collector.yaml         # api scrape jobs
├── terraform/environment/      # app_hostname, rentsync_* write-only secrets → SSM
└── terraform/shared/           # ECR rentsync/api, IAM push/pull
.github/workflows/              # ci.yml (api jobs, ingestion-e2e), release.yml, deploy-to.yml
compose.yaml                    # api, api_worker services
docs/adr/0009–0012, docs/deploy/runbook.md, docs/deploy/production-differences.md
```

**Structure Decision**: a new `api/` service beside `mock_pms/`, both shipped by the 002
pipeline. `/web` is not created until the dashboard feature (R12).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Constitution III's end-to-end test stops at the persisted raw event, not a ledger effect | The ledger is the next feature; there is no ledger effect to assert yet | Building a stub ledger only to satisfy the test would be throwaway work. The ledger feature MUST extend this test to the ledger entry (spec, Assumptions) |
| Constitution II: a crash between the PMS creating RentSync's client and RentSync storing its secrets leaves an orphan client at the PMS when registration is retried | The mock's `POST /admin/clients` returns secrets only once and refuses `Idempotency-Key` for that reason (001 openapi), so the effect cannot be deduplicated | Adding idempotent replay of secret-bearing responses to the mock would store client secrets in its idempotency table, which is worse. The orphan holds no grants, so it receives no events and cannot read data; it is named `rentsync-<deployment_id>` for cleanup (R9). Concurrent runs are prevented by an advisory lock |
