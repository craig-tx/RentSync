# Implementation Plan: Mock Property Management System (PMS)

**Branch**: `001-mock-pms` | **Date**: 2026-10-20 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-mock-pms/spec.md`

**Note**: `/speckit-plan` was run without arguments. The tech stack and constraints come from
the reusable plan prompt in `rentsync-speckit-kickoff.md` §3, narrowed to this feature.

## Summary

Build `/mock_pms`, a small standalone Ruby service that simulates a property management
system vendor. RentSync's integration layer (feature 002) will be developed and demonstrated
against it. It provides:

- an OAuth 2.0 authorization server (authorization code flow plus rotating refresh tokens,
  with 5-minute access tokens);
- a paginated read API for operator-scoped portfolio data, with per-client rate limits;
- signed webhooks (HMAC-SHA256);
- runtime-adjustable chaos injection;
- an admin API for replays, scenarios, grant revocation, and reseeding.

The main technical choices:

- **Webhook delivery** uses a Postgres-backed transactional outbox, drained by a separate
  worker process. Each chaos decision is made when its delivery is created and stored with it.
  The random value comes from an HMAC of the seed and a draw counter kept in the database, so
  a given seed reproduces the same run whichever process or thread does the work, and across
  restarts.
- **Seed data** is deterministic, driven by `(SEED, SEED_ANCHOR_DATE)`. Seeded rows take their
  IDs and timestamps from the seed, so their digest is identical on every reseed.
- **Pagination** is keyset-based on an immutable sequence, so pages stay stable while new
  records are inserted.
- **Rate limiting** is an exact token bucket per client, stored in Redis and updated atomically
  by a Lua script. The web tier holds no rate-limit state, so it can run as any number of
  processes or containers.

See [research.md](research.md) for each decision.

## Technical Context

**Language/Version**: Ruby ≥ 3.3

**Primary Dependencies**: Grape and Puma on Rack, Sequel with `pg`, bcrypt, and `redis`.
Everything else comes from the Ruby standard library. The [Dependencies](#dependencies) table
gives the justification for each one (Constitution VIII).

**Storage**: PostgreSQL 16, in a dedicated `mock_pms` database (R2), for all durable data.
Redis 7 holds rate-limit buckets (R8) and metric totals for the whole cluster (R12). That data
is short-lived: losing it resets limits and counters, but never loses business data.

**Testing**: RSpec and Rack::Test, run against a real Postgres test database and a real Redis.
One end-to-end delivery test uses a real local receiver. RuboCop handles linting.

**Telemetry**: an OpenTelemetry Collector (`contrib` distribution) delivers logs from JSON
stdout and metrics from Prometheus `/metrics` over OTLP/HTTP to OpenObserve (R16). The
services have no OTel SDK dependency. Image versions are pinned during implementation.

**Target Platform**: Linux containers, with Docker Compose for local development and CI. The
development machine is Windows 11 with Docker Desktop.

**Project Type**: Web service (an HTTP API plus a background worker process). There is no
front end, apart from a single server-rendered approval page.

**Performance Goals**:

- Webhooks are delivered within 5 s of the business change when chaos is off (SC-003).
- The month-end burst for about 60 leases is fully delivered within 2 minutes (SC-008).
- Seeding finishes in under 1 minute (SC-002).
- The API handles about 60 requests per minute per client by default, which is light load.

**Constraints**:

- Web and worker processes are stateless (Constitution X):
  - Durable state lives in Postgres.
  - Rate-limit buckets and metric totals live in Redis.
  - If Redis is unavailable, the `/v1` API fails closed with a 503 (R8). Metric deltas stay
    buffered until Redis is back (R12).
- Delivery is at-least-once (R6).
- Output must be deterministic for a given seed, for both the seed data and the chaos
  decisions (R5, R7).
- No secrets or personal data may appear in logs (FR-031).

**Scale/Scope**: 3 operators, 50 properties, 60 leases, about 12 months of history (roughly
1,500 charges and payments), and a few registered clients. This is a test harness, not a
product.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Status | Evidence |
|---|---|---|---|
| I | Correctness over cleverness | **N/A (partial)** | There is no RentSync ledger in this feature. The mock's own financial records still follow the intent: reversals are separate rows and never edit a payment in place, `events` and `delivery_attempts` are immutable, and chaos never changes stored data (FR-025) |
| II | Idempotency everywhere | **PASS** | See the [Idempotency keys](#idempotency-keys) table. The mock produces stable event IDs, enforces single-use codes and refresh tokens, and supports `Idempotency-Key` on side-effecting admin POSTs. Delivery is at-least-once, by design (R6) |
| III | Test-first for domain logic | **PASS** | The test-first units are listed in R13: signature generation, token lifecycle, pagination stability, seed determinism, chaos decisions, retry schedule, and admin idempotency. An end-to-end delivery test runs against a real receiver. The rate-limit script is tested against a real Redis. A minimal `.github/workflows/ci.yml` (rubocop and rspec, with Postgres and Redis services) is part of this feature, so the rule that CI must be green before merge applies from the first merge. Feature 007 extends it (R15) |
| IV | Integrations are hostile by default | **PASS** | This feature *creates* the hostility: duplicates, reordering, delays, malformed bodies, injected 500s, 429s with Retry-After, and short-lived tokens. Every chaos effect has a measurement definition (R7) and a check in the quickstart |
| V | AI agents propose, humans dispose | **N/A** | This feature has no agent and no ledger |
| VI | Observable by default | **PASS (exceeds spec)** | **Logs and metrics are delivered over OTLP to OpenObserve through an OpenTelemetry Collector bridge (R16).** The Collector's `filelog` receiver reads the services' JSON stdout, and its `prometheus` receiver scrapes `/metrics`. Neither service has an OTel SDK dependency, because the Ruby metrics and logs SDKs are still 0.x. The backend is configuration only. Export runs outside the request path, so it never blocks or fails work. Log lines use OTel field names: `service.name`, `service.version`, `deployment.environment`, `service.instance.id`, and **`code.function.name`** (the calling method, captured automatically), plus `correlation_id`. OpenObserve runs in Compose and in the CI telemetry-smoke job (R15). JSON logs with correlation IDs; `/healthz` covers the database, Redis, and the worker heartbeat; `/metrics` reports totals for every instance: request and send-latency metrics come from Redis, and delivery metrics come from database aggregates (R12). This **goes beyond FR-030**, which lists only health and logs, because the constitution requires metrics on every service. The mock is where correlation IDs start: each event stores one and sends it as `X-Correlation-Id` (R10) |
| VII | Secure by default | **PASS** | Outbound webhooks are HMAC-signed. Codes, tokens, and client secrets are stored only as SHA-256 digests, as VII requires for tokens a system only verifies; passwords use bcrypt. Admin requires a bearer token compared in constant time. Logs are redacted inside the service before they are written. The Collector strips the same keys again before export (R16), and the OpenObserve credentials come only from `.env`. Each operator is scoped server-side on every `/v1` query. **Design note**: webhook signing secrets are stored as given, because the mock must sign with them. VII sets no at-rest rule for them, and they are synthetic, local-only, test-harness secrets (R4) |
| VIII | Simplicity | **PASS** | There are 6 runtime gems, each justified below. The Redis service is already part of the project stack (kickoff §3). The mock uses it only for rate limiting and metric totals. The OAuth server, metrics, seed names, and rate-limit script are hand-written rather than pulled in as dependencies. Telemetry adds no gems: the Collector and OpenObserve are infrastructure, configured in `infra/otel/collector.yaml` and `compose.yaml`. There are no unjustified abstractions |
| IX | Documented decisions | **PASS (follow-up)** | Four ADRs are required and will be written as tasks during implementation (see [ADRs to write](#adrs-to-write)). None are written by this command |
| X | Stateless, horizontally scalable services | **PASS** | No process keeps shared state in memory. Grants, codes, tokens, events, deliveries, chaos counters, idempotency keys, and heartbeats are in Postgres. Rate-limit buckets (R8) and metric totals (R12) are in Redis. Workers claim deliveries with `SKIP LOCKED`, and the reaper requeues stalled ones, so any number of workers is safe (R6). Every shared write is atomic: conditional `UPDATE`s, unique constraints, the Lua token bucket, and `HINCRBY`/`HINCRBYFLOAT` in `MULTI`. **One lock, justified:** web and worker processes run pending migrations at boot under a Postgres advisory lock, so concurrent instances wait their turn instead of racing. That is a single-runner job holding a lock in the shared store, which X allows; it was added during implementation. Nothing else locks, and the request and delivery paths take no locks. Process memory holds only per-request data, configuration, the cached Lua script SHA (reloaded on `NOSCRIPT`), and the metric delta buffer. A crash loses at most one 5-second flush interval of metrics from that process (R12). `mock_pms_b` in the quickstart checks this across instances |
| — | Scope & data constraints | **PASS** | The mock is a test harness that stays small but realistic. All seed data is synthetic (R5). The stack is recorded here, not in the constitution |
| — | Workflow & quality gates | **PASS** | `/speckit-analyze` runs before `/speckit-implement`. Every dependency is justified. CI gates merges from this feature onward (R15). The Compose file and CI workflow are scoped to the mock, and feature 007 extends both to the full stack |

**Gate result (pre-research)**: PASS. No violation needs a Complexity Tracking entry.

**Gate result (post-design)**: PASS. Re-checked against [data-model.md](data-model.md) and
[contracts/](contracts/). The design added `admin_idempotency_keys` (II), `worker_heartbeats`
and `/metrics` (VI), and an immutable `delivery_attempts` table (I, by intent). A later
revision moved rate limiting to Redis, which added the `redis` gem and a Redis service. That
dependency is justified below, and the gate still passes. After constitution v1.1.0 added
Principle X, request metrics also moved to Redis, through buffered atomic flushes. That change
added no dependencies, and the gate still passes. Principle VI's OTLP rule added the
Collector bridge, OpenObserve, and a CI telemetry-smoke job (R16, R15). They add no gems, and the
gate still passes.

### Idempotency keys

| Key | Protects | Mechanism |
|---|---|---|
| `events.id` (`PMS-Event-Id`) | Receivers against duplicate processing across retries, chaos duplicates, and replays | Immutable and unique. The same value goes in every delivery of an event |
| `authorization_codes.code_digest` + `used_at` | Code reuse (spec edge case) | A single-use conditional `UPDATE`, in the same transaction as token issuance |
| `refresh_tokens.token_digest` + `used_at` | Refresh replay (spec edge case) | The same single-use update. Rotation issues a new pair |
| `Idempotency-Key` header on admin POSTs | Running a scenario, replay, revocation, or reset twice when a client retries | The stored response is returned for the same key and body; a different body returns 422 (R11) |
| `(lease_seq, kind, period)` unique | Duplicate monthly charges from seed or scenario reruns | Database unique constraint |
| `reversals.payment_seq` unique | Reversing a payment twice | Database unique constraint |
| `grants (client, operator) WHERE revoked_at IS NULL` | Duplicate active grants on re-approval | Partial unique index; the existing grant is reused |

### Dependencies

| Gem | Purpose | Justification |
|---|---|---|
| `grape` | HTTP API framework | Matches the main `/api` service, and gives declarative parameter validation (R1) |
| `puma` | Rack server | The standard threaded Ruby server. It also hosts the receiver in the end-to-end test |
| `sequel` | Database access and migrations | The project-standard ORM from kickoff §3. It handles `SKIP LOCKED` and `jsonb` easily (R2, R6) |
| `pg` | Postgres driver | Sequel needs it to talk to PostgreSQL |
| `bcrypt` | Operator password hashing | The standard slow password hash; the stdlib has no replacement (R4) |
| `redis` | Redis client for rate limiting and metrics | The official Ruby client. It supports `EVALSHA` for the atomic token-bucket script (R8) and `MULTI` with `HINCRBY` for metric flushes (R12), which keeps the processes stateless (Constitution X) |
| `rspec` *(dev)* | Test framework | The project standard (kickoff §3) |
| `rack-test` *(dev)* | Request specs | The standard way to drive a Rack app in tests |
| `rubocop` *(dev)* | Lint | CI runs a lint step (kickoff §7) |

The following come from the stdlib, so no gem is added: `json`, `erb`, `openssl` (HMAC and
digests), `securerandom`, `net/http`, `logger`, and `random`.

### ADRs to write

These are created as tasks during implementation, in `docs/adr/`:

1. **ADR-0001: Transactional outbox for mock webhook delivery.** Chose Postgres and a worker
   over Sidekiq and Redis, and records the at-least-once semantics (R6).
2. **ADR-0002: Hand-written OAuth 2.0 authorization server with opaque, hashed tokens.**
   Doorkeeper requires Rails; JWT was rejected because it makes revocation harder (R3).
3. **ADR-0003: Redis-backed token-bucket rate limiter.** Explains the choice of a Lua script
   for atomic updates and Redis `TIME` as the shared clock, and records the fail-closed policy
   when Redis is unavailable. It also records the alternatives rejected: an in-process bucket,
   which requires a single process; a Postgres counter; and a fixed window (R8).
4. **ADR-0004: OTLP telemetry through a Collector bridge to OpenObserve.** The services emit
   stable standard formats (JSON stdout and Prometheus text), and the Collector converts them
   to OTLP. The alternative, in-process OTel SDKs, was rejected for now because the Ruby
   metrics and logs SDKs are pre-1.0. The ADR also states when to revisit that (R16).

## Project Structure

### Documentation (this feature)

```text
specs/001-mock-pms/
├── plan.md              # This file
├── research.md          # Phase 0: decisions R1–R15
├── data-model.md        # Phase 1: tables, state machines, traceability
├── quickstart.md        # Phase 1: end-to-end validation guide
├── contracts/
│   ├── openapi.yaml     # OAuth, /v1 data, /admin, /healthz, /metrics
│   └── webhooks.md      # Envelope, headers, signature, retries, chaos effects
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
mock_pms/
├── Gemfile
├── Dockerfile                  # Ruby 3.3 slim; one image for web and worker
├── config.ru
├── config/
│   ├── puma.rb                 # threads; workers configurable (stateless web tier)
│   └── settings.rb             # ENV → typed config (TTL, limits, retry base, ADMIN_TOKEN, SEED…)
├── bin/
│   ├── setup                   # create DB, migrate, seed
│   ├── reseed                  # --seed --anchor → prints data_digest
│   ├── seed_report             # counts and behaviour mix, operator logins
│   ├── delivery_worker         # outbox poller + heartbeat
│   ├── test_receiver           # signature-verifying receiver; JSONL log; --fail-first N
│   ├── hammer                  # rate-limit probe
│   └── chaos_check             # observed vs configured rates; --determinism
├── db/
│   └── migrations/
├── lib/mock_pms/
│   ├── app.rb                  # Rack builder: middleware stack + Grape mounts
│   ├── db.rb
│   ├── redis.rb                # connection + script loading (EVALSHA, reload on NOSCRIPT)
│   ├── rate_limit/token_bucket.lua
│   ├── models/                 # Sequel models per data-model.md
│   ├── api/
│   │   ├── oauth.rb            # /oauth/authorize (HTML), /oauth/token
│   │   ├── v1.rb               # /v1 resources
│   │   ├── admin.rb            # /admin/*
│   │   └── ops.rb              # /healthz, /metrics
│   ├── views/authorize.html.erb
│   ├── oauth/                  # code/token issuance, rotation, validation (expired vs invalid)
│   ├── pagination.rb           # keyset cursor encode/decode
│   ├── middleware/
│   │   ├── correlation_id.rb
│   │   ├── rate_limiter.rb     # calls the Redis token-bucket script; 429 + Retry-After; fail-closed 503
│   │   └── chaos_errors.rb     # 500 injection for /v1/* only
│   ├── events/
│   │   ├── recorder.rb         # business change → event + deliveries (same txn); fan-out
│   │   └── serializer.rb       # envelope + /v1 resource shapes
│   ├── delivery/
│   │   ├── signer.rb           # PMS-Signature
│   │   ├── worker.rb           # claim (SKIP LOCKED), send, record attempt, backoff, reaper
│   │   ├── transport.rb        # Net::HTTP wrapper (injectable)
│   │   └── malformer.rb        # truncate / drop_field / bad_type
│   ├── chaos/
│   │   ├── settings.rb
│   │   └── decider.rb          # HMAC(seed, stream:counter:field) draws; decisions persisted on deliveries
│   ├── seed/
│   │   ├── generator.rb        # (seed, anchor_date) → portfolio + historical events
│   │   ├── wordlists.rb
│   │   └── digest.rb           # canonical dump → SHA-256
│   ├── scenarios/
│   │   ├── month_end_burst.rb
│   │   ├── nsf_wave.rb
│   │   └── tenant_move_out.rb
│   ├── admin/idempotency.rb
│   ├── metrics/
│   │   ├── buffer.rb           # Mutex-guarded delta buffer; O(1) swap; cap + dropped counter
│   │   ├── flusher.rb          # periodic MULTI of HINCRBY/HINCRBYFLOAT; merge-back on failure; final flush
│   │   └── exposition.rb       # Redis hashes + DB aggregates → Prometheus text
│   └── logging.rb              # OTel-named JSON fields; Loggable mixin → code.function.name; redaction
└── spec/
    ├── spec_helper.rb
    ├── fixtures/signature_vector.json
    ├── unit/                   # signer, oauth lifecycle, pagination, decider, retry schedule, seed digest, malformer, rate limiter
    ├── requests/               # oauth, v1 scoping/pagination, admin, ops, 401/429/500 shapes
    └── integration/
        └── delivery_end_to_end_spec.rb   # real receiver; signature + retry + chaos duplicate

compose.yaml                    # postgres:16, redis:7, mock_pms (:4001), mock_pms_worker, otel-collector, openobserve (:5080); tools profile: mock_pms_b, receiver — extended by feature 007
infra/otel/collector.yaml       # filelog + prometheus receivers → memory_limiter, batch, redaction → otlphttp (OpenObserve)
.env.example                    # all mock_pms settings, no real secrets
.github/workflows/ci.yml        # job 1: rubocop + rspec (postgres:16, redis:7); job 2: telemetry-smoke via compose + OpenObserve query — extended by feature 007
docs/adr/                       # ADR-0001..0003 (created during implement)
```

**Structure decision**: the mock is one self-contained service under `/mock_pms`, as the
kickoff layout prescribes. It has two process types (web and worker), both built from one
image. No other top-level directories are touched except a minimal `compose.yaml`,
`.env.example`, `.github/workflows/ci.yml`, `infra/otel/collector.yaml`, and `docs/adr/`. Feature 007 extends the Compose
file and CI to the full stack.

## Complexity Tracking

None. The Constitution Check has no violations to justify.

- **Tokens**: Principle VII (v1.1.0) requires one-way hashing for tokens a system only
  verifies, and the mock does exactly that.
- **Signing secrets**: storing webhook signing secrets as given is a recorded design choice
  (research R4), not a violation, because VII sets no at-rest rule for them.
