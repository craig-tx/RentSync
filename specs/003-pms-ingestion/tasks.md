---

description: "Task list for feature 003: PMS Connection and Webhook Ingestion"
---

# Tasks: PMS Connection and Webhook Ingestion

**Input**: Design documents from `/specs/003-pms-ingestion/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/openapi.yaml](contracts/openapi.yaml),
[contracts/webhook-receiver.md](contracts/webhook-receiver.md),
[contracts/pms-changes.md](contracts/pms-changes.md),
[contracts/host-changes.md](contracts/host-changes.md), [quickstart.md](quickstart.md)

**Tests**: **required**. Constitution Principle III (non-negotiable) requires test-first
development; research R17 lists the units. In each phase the test tasks come first, and each
MUST be run and seen to fail before the implementation task it covers starts.

**Organization**: grouped by user story (US1–US4 from spec.md). Deployment (FR-025) is its own
phase after the stories, because it ships all of them.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel with other [P] tasks in the same phase (different files, no
  dependency on unfinished tasks).
- **[Story]**: the user story the task belongs to.
- **🧑 OPERATOR**: only the operator can do it (HCP applies, DNS, approvals). Claude prepares
  everything around it.
- Paths are relative to the repository root. RentSync's code lives in `api/`.

## Conventions for every task

- **Ruby**: Ruby ≥ 3.3, `# frozen_string_literal: true` in every file, namespace `Rentsync::`.
- **Copied modules** (research R1): when a task says "adapt from the mock", copy the named
  `mock_pms/lib/mock_pms/…` file, rename the namespace, remove what RentSync doesn't need, and
  copy or write its spec too. Never `require` anything from `mock_pms/`.
- **Tests**: RSpec. Request specs use Rack::Test against `Rentsync::App`. Database examples run
  in a rolled-back transaction. Redis examples use the prefix `rentsync:test:<pid>:` and clean
  up after themselves.
- **Time and randomness**: domain code uses `Rentsync::Clock` and `Rentsync::Ids` (T012), never
  `Time.now` or `SecureRandom` directly, so tests can inject them.
- **Logging**: only through `Rentsync::Logging::Loggable` (T013). Never log tokens, secrets,
  passwords, cookie values, signature headers, webhook bodies, payloads or tenant data
  (Constitution VII, FR-003, FR-024).
- **Shared state**: in Postgres or Redis, updated atomically (conditional `UPDATE`, unique
  constraints, Lua). Nothing shared lives in process memory (Constitution X).
- **Migrations**: expand-only (002 research R9). `raw_events` is never updated or deleted.
- **Cross-platform**: scripts are Ruby or bash 4.4+; docs give Windows and macOS steps where
  they differ.
- **Commits**: run `bundle exec rspec` and `bundle exec rubocop` in `api/` (and in `mock_pms/`
  when it changed) before each commit.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: an empty `api` service that builds, boots, lints and runs an empty test suite
locally and in CI.

- [x] T001 Create `api/Gemfile` with exactly the gems in plan.md "Dependencies" (runtime:
  `grape`, `puma`, `sequel`, `pg`, `bcrypt`, `redis`; dev/test: `rspec`, `rack-test`,
  `rubocop`), the comment pointing at plan.md, `ruby ">= 3.3"`, and generate `api/Gemfile.lock`
  with platforms `x86_64-linux`, `aarch64-linux`, and the developer's platform.
- [x] T002 [P] Create `api/Dockerfile` adapted from `mock_pms/Dockerfile` (Ruby 3.3 slim, one
  image for web and worker, non-root user, `GIT_SHA` build arg into `SERVICE_VERSION`,
  `ENV MALLOC_ARENA_MAX=2`, `EXPOSE 4002`) and `api/.dockerignore`.
  *Done on `ruby:4.0-slim`, the base the mock's Dockerfile now uses, so both images share one
  runtime; CI still tests on Ruby 3.3. Approved by the operator on 2026-10-29.*
- [x] T003 [P] Create `api/.rubocop.yml` (copy the mock's, same cops, including the cop that
  forbids direct `Logger` calls outside `logging.rb`) and `api/.rspec`.
- [x] T004 [P] Create `api/config/puma.rb`: single mode (no `workers`), `threads 3, 3`,
  `port ENV.fetch("PORT", 4002)`.
- [x] T005 Create `api/config.ru`, `api/lib/rentsync.rb` (requires, `Rentsync::VERSION` from
  `SERVICE_VERSION`), and a placeholder `api/lib/rentsync/app.rb` returning 404 for everything.
- [x] T006 Add `api` and `api_worker` services to the root `compose.yaml`: build `./api`,
  ports `4002:4002`, `depends_on` postgres, redis and mock_pms healthy; the worker runs
  `bundle exec bin/worker`; environment from `.env` per plan.md "Configuration", with the local
  URL values from research R13 (`PMS_PUBLIC_URL=http://localhost:4001`,
  `PMS_API_URL=http://mock_pms:4001`, `APP_PUBLIC_URL=http://localhost:4002`,
  `WEBHOOK_SUBSCRIBER_URL=http://api:4002/webhooks/pms`), and
  `MOCK_PMS_ADMIN_TOKEN: ${ADMIN_TOKEN}` (the mock's admin token, for registration, R9).
- [x] T007 Add every new setting to `.env.example` (plan.md "Configuration") with safe local
  values. The development encryption key is `k1=` plus a clearly fake base64 value, with a
  comment that it must never be used on a host.
- [x] T008 [P] Create `api/spec/spec_helper.rb` and `api/spec/support/{db.rb,redis.rb,clock.rb}`
  adapted from the mock's (transaction rollback, Redis prefix, injectable clock), using
  `RENTSYNC_TEST_DATABASE_URL`.
- [x] T009 Add an `api` job to `.github/workflows/ci.yml` mirroring the `test` job (Postgres and
  Redis services, `working-directory: api`, `bin/setup --test-db-only`, rubocop, rspec,
  bundle-audit), with pinned action SHAs as in the existing jobs.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: configuration, logging, metrics, database, encryption, the PMS client
registration, and the shared tables every story uses.

**⚠️ CRITICAL**: no user story work begins until this phase is complete.

### Tests for the foundation (write first; they must fail)

- [x] T010 [P] Unit spec `api/spec/unit/crypto/box_spec.rb` for research R8: round trip; output
  format `v1:<key_id>:<nonce>:<ciphertext+tag>`; a fresh 12-byte nonce each time (two
  encryptions differ); decrypting with a different associated data string (another row ID or
  column) raises; a flipped ciphertext bit raises; the first key in
  `RENTSYNC_ENCRYPTION_KEYS` encrypts and any listed key decrypts; an unknown key ID raises;
  malformed key configuration fails at boot with a message that never contains a key.
- [x] T011 [P] Unit spec `api/spec/unit/settings_spec.rb`: required variables fail fast with
  their names (never values); `RECONCILE_INTERVAL_S` defaults to 900 and
  `RECONCILE_OVERLAP_S` to 3600; the PMS bucket defaults to 50 per minute; the four URL
  settings are required and must be absolute URLs.

### Implementation for the foundation

- [x] T012 [P] `api/lib/rentsync/clock.rb`, `api/lib/rentsync/ids.rb` (prefixed public IDs:
  `opr_`, `con_` + 20 base32 chars), `api/lib/rentsync/central_time.rb`: adapt from the mock.
- [x] T013 [P] `api/lib/rentsync/logging.rb`: adapt from the mock (OTel field names,
  `code.function.name`, `correlation_id`, redaction). Add `access_token`, `refresh_token`,
  `client_secret`, `signing_secret`, `code_verifier`, `password`, `cookie`, `pms-signature` and
  `payload` to the redacted keys, with a spec proving each is redacted.
- [x] T014 [P] `api/lib/rentsync/metrics/{buffer,flusher,exposition}.rb` and
  `api/lib/rentsync/middleware/{correlation_id,request_metrics}.rb`: adapt from the mock, with
  their specs. Redis keys use the `rentsync:` prefix.
- [x] T015 `api/config/settings.rb`: ENV → typed config, passing T011.
- [x] T016 `api/lib/rentsync/crypto/box.rb`: AES-256-GCM with stdlib `OpenSSL::Cipher`,
  passing T010.
- [x] T017 `api/lib/rentsync/db.rb` and `api/lib/rentsync/redis.rb`: adapt from the mock,
  including migrations at boot under a Postgres advisory lock. Redis database 1.
- [x] T018 Migration `api/db/migrations/001_foundation.rb` creating, exactly as data-model.md
  specifies:
  - `operators`: `email` text with a unique index on `lower(email)`; `password_digest`;
    `public_id` unique.
  - `pms_clients`: `pms_key`, `base_url`, `client_id`, `client_secret` (enc),
    `signing_secret` (enc), `registered_at`, `superseded_at`, with "exactly one row per
    `pms_key` has `superseded_at IS NULL` (partial unique index)".
  - `pms_connections`: every column in data-model.md; unique `(pms_client_id,
    pms_operator_id)`; unique `(operator_id, pms_client_id)`; check
    `status IN ('active','renewal_failing','needs_reauth','disconnected')`.
  - `maintenance_leases`: `name` PK, `lease_until`, `last_run_at`.
- [x] T019 [P] `api/lib/rentsync/models/{base,operator,pms_client,pms_connection}.rb`: Sequel
  models with helpers that encrypt and decrypt the **enc** columns, using associated data
  `"<table>.<column>:<id>"` (R8). Rows are inserted first and their secrets written in the
  same transaction, so the ID exists for the associated data.
- [x] T020 Spec then implementation of `Rentsync::Pms::Registration.ensure!`
  (`api/lib/rentsync/pms/registration.rb`, spec with a fake mock admin API), per research R9.
  It runs inside `pg_advisory_xact_lock` on a fixed key:
  - no active client: `POST /admin/clients` with name `rentsync-<DEPLOYMENT_ID>`, redirect URI
    `<APP_PUBLIC_URL>/connections/callback`, subscriber URL `<WEBHOOK_SUBSCRIBER_URL>`; store the
    secrets encrypted;
  - active client still in the mock's `GET /admin/clients` list: no change;
  - active client missing (a mock reset): mark it superseded, register again, and set every
    connection under the old client to `needs_reauth`;
  - two concurrent calls make exactly one `POST /admin/clients` (the advisory lock) and leave
    exactly one active row;
  - the client and signing secrets never appear in logs or output.

  *Only live connections (`active`, `renewal_failing`) go to `needs_reauth`, per data-model.md's
  state machine; disconnected ones stay disconnected. Approved by the operator on 2026-10-29.*
- [x] T021 `api/bin/setup`, adapted from the mock's. It creates the database if missing,
  migrates, seeds operators (T030, once it exists), and runs `Registration.ensure!` (skipped by
  `--test-db-only`). `--deploy` is safe to rerun. It prints the PMS client ID and the operator
  emails, never secrets. Plus `api/bin/pms_client` (`--show` prints client ID and registration
  time; `--set` reads credentials from stdin for a real PMS).
- [x] T022 `api/lib/rentsync/api/ops.rb`: `/healthz` with the same fields as the mock's Health
  schema (db, redis, `worker_heartbeat_age_s`, version, deployment_id, time, started_at,
  `*_ct`), `/healthz/live`, and `/metrics`. Request spec `api/spec/requests/ops_spec.rb`.
- [x] T023 `api/bin/worker`: a loop with a heartbeat row in the `worker_heartbeats` table from data-model.md
  (`worker_id` text PK, `beat_at`; add it to T018's migration), a `/metrics` endpoint on port 4003, graceful stop on SIGTERM, and a job
  registry that later phases add to. Spec for the loop's stop behaviour.
- [x] T024 `api/lib/rentsync/app.rb`: the Rack builder. Order: correlation ID, request metrics,
  the webhook endpoint mount point (US2), session middleware (US1), Grape API, pages.

**Checkpoint**: `docker compose up` brings `api` and `api_worker` up healthy, `bin/setup`
registers RentSync with the mock, and the CI `api` job is green.

---

## Phase 3: User Story 1 - Connect a PMS account (Priority: P1) 🎯 MVP

**Goal**: an operator signs in, connects their mock PMS account, and the connection stays
usable through access-token expiry, revocation and disconnection.

**Independent Test**: quickstart §2.

### Tests for User Story 1 (write first; they must fail) ⚠️

- [x] T025 [P] [US1] Mock PMS request spec `mock_pms/spec/requests/oauth_spec.rb`: token
  responses for both grant types include `operator_id` and `operator_name`, and
  `operator_id` equals the operator in that grant's webhook envelopes
  (contracts/pms-changes.md).
- [x] T026 [P] [US1] Unit spec `api/spec/unit/auth/passwords_and_sessions_spec.rb`: bcrypt
  verify; the session cookie token is 32 random bytes and only its SHA-256 is stored; idle
  expiry 12 h and absolute 7 days; sign-out sets `revoked_at`; CSRF tokens are per session and
  compared in constant time.
- [x] T027 [P] [US1] Unit spec `api/spec/unit/pms/oauth_spec.rb`:
  - the authorize URL carries `response_type=code`, `client_id`, the redirect URI, `scope=read`,
    `state`, `code_challenge` (S256 of the verifier) and `code_challenge_method=S256`, built on
    `PMS_PUBLIC_URL`;
  - the code exchange posts to `PMS_API_URL/oauth/token` with the verifier and client
    credentials;
  - **renewal lease**: two concurrent renewals for one connection make exactly one PMS call
    (the loser waits up to 5 s and rereads); a renewal is attempted when
    `access_expires_at < now + 60 s`;
  - `invalid_grant` or `invalid_client` → `needs_reauth`; a timeout, `5xx` or connection error
    → `renewal_failing` with `renewal_failures` incremented and a backoff, then `active` again on
    success.
- [x] T028 [P] [US1] Request spec `api/spec/requests/connections_spec.rb`:
  - sign-in success, generic failure for unknown email and wrong password alike, the 6th attempt
    in a minute → 429 (per email and per IP);
  - `POST /connections` without a CSRF token → 403;
  - the callback: unknown, expired, used, or another operator's `state` → 400 and nothing
    stored; `error=access_denied` → outcome `denied`, nothing stored (US1 AC2); success →
    `active` with the PMS operator's name (AC1);
  - reconnect after `needs_reauth` keeps the same connection row (FR-008); a PMS operator
    already connected by another RentSync operator → `pms_operator_taken`;
  - disconnect nulls both tokens, sets `disconnected`, and keeps raw events (AC5);
  - operator B gets 404 for operator A's connection pages and JSON (AC6, FR-023).

  *2026-10-29: "keeps raw events" is now asserted, since T040 exists. It passed when first run:
  nothing deletes raw events, and the trigger would refuse a deletion anyway.*

  *Two assertions wait for later tables: "keeps raw events" needs `raw_events` (T040), and the
  health page's 404 for another operator needs the health page (US4). The spec covers
  disconnect and the 404 on another operator's disconnect now. Requests use
  `https://app.test`, because the cookie is `Secure` off localhost. The spec also covers a
  second, different PMS account for the same operator: refused as `different_pms_account`,
  since `(operator_id, pms_client_id)` is unique.*

### Implementation for User Story 1

- [x] T029 [US1] Mock PMS: add `operator_id` and `operator_name` to both token responses in
  `mock_pms/lib/mock_pms/oauth/service.rb` and `mock_pms/lib/mock_pms/api/oauth.rb`; update the
  `TokenResponse` schema in `specs/001-mock-pms/contracts/openapi.yaml`. Passes T025.
- [x] T030 [US1] Migration `api/db/migrations/002_auth_and_attempts.rb`: `sessions`
  (`token_sha256` bytea unique, `csrf_secret`, `created_at`, `last_seen_at`, `revoked_at`) and
  `connection_attempts` (`state_sha256` bytea unique, `code_verifier` enc, `expires_at` =
  created + 10 min, `used_at`, `outcome` in `connected|denied|failed|expired`, `error_code`).
  Operator seeding in `api/lib/rentsync/seed/operators.rb`: one operator per mock PMS operator,
  synthetic emails `operator<n>@example.test`, password from
  `RENTSYNC_OPERATOR_SEED_PASSWORD`, idempotent.
  *Both tables also have `operator_id`, and `connection_attempts` has `created_at` for the
  purge. The mock's admin API has no operator list, so `Seed::Operators::LIST` mirrors the
  mock's fixed seed (three operators, by name and mock login). `bin/connect_operator` uses the
  same list. Existing operators are left unchanged.*
- [x] T031 [US1] `api/lib/rentsync/auth/{passwords,sessions,csrf,sign_in_throttle}.rb` and the
  session middleware: cookie `rentsync_session`, `HttpOnly`, `Secure` unless `APP_PUBLIC_URL`
  is `http://localhost…`, `SameSite=Lax`. The throttle uses the mock's Redis token-bucket script,
  copied now into `api/lib/rentsync/rate_limit/token_bucket.lua`, at 5 per minute.
  Passes T026.

  *2026-10-29: at the operator's request, `POST /sign-in` now refuses login CSRF (research
  R11). The check runs before the throttle, so a refused post never spends a throttle token.
  The spec was seen failing first. Checked live: a forged `Origin` gets 403, and
  `bin/connect_operator`, which sends neither header, still connects.*
- [x] T032 [US1] `api/lib/rentsync/pms/oauth.rb`: the authorize URL, code exchange and renewal
  lease, with the state machine transitions in data-model.md. Passes T027.
  *The renewal backoff (5 s doubling to a 300 s cap) is kept in `renewal_lease_until`, so
  nobody retries before it ends. A refusal other than `invalid_grant` or `invalid_client` counts
  as temporary (FR-006). The connect flow is in `pms/connect.rb`, and `Pms.redirect_uri` is
  shared with `Registration`. The live check against the mock renewed a real token.*
- [x] T033 [US1] Pages and routes in `api/lib/rentsync/web/` (ERB views, one small stylesheet,
  no JavaScript): `/sign-in`, `/sign-out`, `/connections` (list, connect, reconnect, disconnect),
  `/connections/callback`, and the `/v1/connections` JSON alias, per contracts/openapi.yaml.
  Every query is scoped by the session's operator. Passes T028.
  *The pages are a Grape API (`api/lib/rentsync/api/pages.rb`), so they get route-template
  metric labels; the views and renderer are in `web/`. The stylesheet is inline in the layout.*
- [x] T034 [US1] `api/bin/connect_operator --operator <n>`: a headless driver of the browser
  side (sign in to RentSync, follow the redirect, post the mock's approval form, follow the
  callback) using `Net::HTTP` with a cookie jar. It runs on the developer machine or CI runner,
  not in a container (research R13), and never prints passwords or tokens.
- [x] T035 [US1] Purge of `connection_attempts` older than 7 days, as a worker job under the
  `daily_purge` lease (T054 adds receipts to the same job).

**Checkpoint**: quickstart §2 passes locally.
*2026-10-29, partly met. Passing locally:*
- *steps 1 to 3: connect, deny, and the headless driver, with a reconnect that reuses the row;*
- *a forced live renewal against the mock;*
- *step 6's scoping, in the request spec.*

*Still to come:*
- *steps 4 and 5 need **Reconcile now** (US3);*
- *step 6's health URL needs US4.*

---

## Phase 4: User Story 2 - Record every PMS event exactly once (Priority: P1)

**Goal**: signed deliveries are verified, recorded once, and every refused delivery is
recorded with a reason.

**Independent Test**: quickstart §3, with a connection made by `bin/connect_operator`.

### Tests for User Story 2 (write first; they must fail) ⚠️

- [X] T036 [P] [US2] Unit spec `api/spec/unit/webhooks/signature_spec.rb`, using
  `api/spec/fixtures/signature_vector.json` copied from `mock_pms/spec/fixtures/`: the vector
  verifies; one changed body byte, a wrong secret, a malformed header, or a missing header
  fails with `bad_signature` or `missing_signature`; `|now − t| > 300` fails with
  `stale_timestamp` and exactly 300 passes; the comparison is constant time (it calls
  `OpenSSL.fixed_length_secure_compare` after a length check).
- [X] T037 [P] [US2] Unit spec `api/spec/unit/webhooks/envelope_spec.rb`: each of the mock's
  malformations (`truncate`, `drop_field`, `bad_type` from `mock_pms/lib/mock_pms/delivery/malformer.rb`)
  is `malformed_body`; an unknown `type` is `malformed_body`; `id` different from
  `PMS-Event-Id` is `malformed_body`; a valid envelope of each of the four types passes.
- [X] T038 [P] [US2] Unit spec `api/spec/unit/webhooks/recorder_spec.rb` (real Postgres): new
  event → `recorded`; same event ID and same body → `duplicate`; same ID with a different body →
  rejected `conflicting_duplicate`, first version unchanged; a `payment.created` whose
  `business_key` was already recorded by reconciliation → `duplicate` with
  `duplicate_of_path = reconciliation`; `operator_id` never connected → `unknown_operator`; only
  a disconnected or `needs_reauth` connection → `no_active_connection`; every outcome writes one
  receipt; `UPDATE` or `DELETE` on `raw_events` raises (the trigger).
- [X] T039 [P] [US2] End-to-end spec `api/spec/e2e/webhook_to_raw_event_spec.rb`
  (Constitution III): a real signed HTTP request through the full Rack stack produces the
  persisted raw event and receipt, the stored `payload_raw` equals the request body byte for
  byte (and `payload` is its parsed JSON), `correlation_id`
  equals the request's `X-Correlation-Id`, and the response is 200 only after commit (a
  failure injected after the insert returns 500 and leaves no raw event). Also the receiver
  table in contracts/webhook-receiver.md: each reason maps to its HTTP status, and error bodies
  never echo body content or header values.

  *2026-10-29: T036–T039 were seen failing first. The unit specs could not load
  (`uninitialized constant Rentsync::Webhooks`), and 13 of 13 end-to-end examples failed, along with the new
  middleware example (`X-Correlation-Id` must win over `X-Request-Id`). T039 is `:committed` and
  runs on a local Puma, so "200 only after commit" is a real commit over real HTTP.*

### Implementation for User Story 2

- [X] T040 [US2] Migration `api/db/migrations/003_events.rb`:
  - `raw_events` with every column in data-model.md, unique `(pms_client_id, event_id)`,
    partial unique `(pms_client_id, business_key) WHERE business_key IS NOT NULL`, indexes
    `(connection_id, received_at)` and `(connection_id, occurred_at)`, and a trigger that
    raises on `UPDATE` or `DELETE`;
  - `webhook_receipts` with every column; `outcome` in `recorded|duplicate|rejected`; `reason`
    required when `rejected` and in the data-model's list; indexes `(connection_id,
    received_at)` and `(operator_id, outcome, received_at)`.
- [X] T041 [P] [US2] `api/lib/rentsync/webhooks/signature.rb` and `envelope.rb`. Pass T036,
  T037.
- [X] T042 [US2] `api/lib/rentsync/webhooks/recorder.rb`: one transaction for the raw event and
  the receipt; `ON CONFLICT DO NOTHING`, then the `payload_sha256` comparison (R4). Business
  keys: `payment.created:<data.object.id>` and `payment.reversed:<data.object.id>`, null for
  lease events. Passes T038.
- [X] T043 [US2] `api/lib/rentsync/webhooks/receiver.rb`: the plain Rack endpoint at
  `POST /webhooks/pms`, mounted first in `app.rb`. It reads at most 256 KiB, and nothing in the
  body is read before the signature passes. Response codes as in the contract; a correlation ID
  is generated when absent. Passes T039.

  *2026-10-29 decisions (T040–T043):*
  - *A `500` writes a receipt with the new reason `internal_error`, in its own transaction after
    the rollback, best effort. data-model.md and the contract now list it.*
  - *Only the active PMS client's signing secret is tried. A delivery signed by a superseded
    registration gets `bad_signature` (pinned in T039).*
  - *`X-Correlation-Id` now wins over `X-Request-Id` in the correlation middleware, so a proxy's
    request ID can never replace the PMS's.*
  - *Header values stored on receipts are capped at 100 characters, because they arrive before the
    signature is checked. The correlation middleware accepts an ID only if it matches
    `\A[\w.:-]{1,128}\z`, which covers the mock's UUIDs and `none`, and generates one
    otherwise. That middleware spec was seen failing first. A body that is not valid UTF-8 is
    `malformed_body`.*
  - *A business-key conflict is always `duplicate`; payload digests are compared only on an
    event-ID conflict.*
  - *Mutation checks, each caught: dropping the digest comparison, accepting any connection
    status, and skipping the size limit.*
- [X] T044 [P] [US2] `api/bin/send_test_webhook` (`--bad-signature`, `--timestamp-offset <s>`,
  `--malformed`, `--operator <pms_operator_id>`) and `api/lib/rentsync/api/admin.rb` with
  `/admin/raw_events` and `/admin/receipts` (admin token, constant-time comparison, no payloads),
  with request specs.

  *2026-10-29: `admin_spec.rb` was seen failing first (7 of 7). Decisions:*
  - *`/admin` takes the mock's `ADMIN_TOKEN` value (`Settings.admin_token` reads
    `MOCK_PMS_ADMIN_TOKEN`), so the hosts need no new secret. The token is compared as SHA-256
    digests with `OpenSSL.fixed_length_secure_compare`; an empty token never matches.*
  - *`/admin/raw_events` also returns each event's `pms_operator_id`, and pages by an opaque
    `next_cursor`.*
  - *`bin/send_test_webhook` runs in the `api` container, where the signing secret can be
    decrypted. It refuses a valid delivery without `--record`, because a test raw event would
    be permanent.*
  - *Checked live against the local stack: each flag got its contract status, and
    `/admin/receipts` counted them.*
- [X] T045 [US2] Metrics `rentsync_webhook_receipts_total{outcome,reason}`,
  `rentsync_raw_events_total{arrival_path,type}` (R16), and the histogram
  `rentsync_webhook_ack_seconds` (buckets 0.05–5 s) on `/webhooks/pms`, from which SC-006's p95
  is read, with an observability spec asserting no
  label carries an operator email, a token or tenant data.

  *2026-10-29: `spec/requests/webhook_metrics_spec.rb` was seen failing first (3 of 4; the
  no-leak example passed only because nothing was counted yet). The shared histogram buckets
  gain a boundary at 2 s, so SC-006's p95 is read off a bucket rather than interpolated between
  1 and 2.5. `buffer_spec`'s pinned bucket list was updated to match on purpose; this is a
  deliberate change, not a weakened test. A `raw_events_total` type comes from the verified
  envelope, never from the `PMS-Event-Type` header. The ack histogram has no labels and times
  every answer, including 500s. Checked live on `/metrics`.*
- [X] T046 [US2] Write `docs/adr/0011-exactly-once-raw-events.md` (context, decision,
  alternatives, consequences), from research R3, R4 and R10.

**Checkpoint**: with chaos on, quickstart §3 shows 0 missing and 0 duplicated events once
US3's reconciliation exists; before that, 0 duplicated and every malformed delivery rejected.

*2026-10-29: the pre-US3 checkpoint passed locally, with quickstart §3's chaos settings and a
`month_end_burst`:*
- *the mock made 28 deliveries of 22 events to RentSync;*
- *RentSync recorded 21 raw events, with 0 duplicated IDs;*
- *every malformed delivery was rejected (27 `malformed_body` receipts), and 4 repeat deliveries
  got `duplicate`.*

*The one missing event had a single delivery, malformed (`drop_field`), which was rejected
until it ran out of attempts. Recovering it is US3's job. `bin/compare_with_pms` (US3) will
automate this comparison; this run used a scratch script. Chaos was reset to 0 afterwards.*

---

## Phase 5: User Story 3 - Catch what webhooks missed (Priority: P2)

**Goal**: scheduled and manual reconciliation records every missing payment and reversal once,
within the PMS's rate limit, resumably.

**Independent Test**: quickstart §4.

### Tests for User Story 3 (write first; they must fail) ⚠️

- [X] T047 [P] [US3] Unit spec `api/spec/unit/pms/client_spec.rb` against
  `api/spec/support/fake_pms.rb` (a Rack app on Puma with scripted responses):
  - every call takes a token from the Redis bucket keyed on the PMS client;
  - a `429` with `Retry-After: 3` sets `rentsync:pms:<client>:blocked_until` (keeping the later
    value), and **another** client instance then waits too;
  - retries use exponential backoff with full jitter (base 1 s, cap 60 s) on `429`, `5xx` and
    timeouts; the 6th failed attempt raises;
  - Redis down → the call waits and does not proceed (fail closed);
  - an expiring access token is renewed first (T032).
- [X] T048 [P] [US3] Unit spec `api/spec/unit/reconciliation/run_spec.rb` (real Postgres, fake
  PMS):
  - first run: no `updated_since` (full backfill), `trigger = initial`;
  - later runs: `updated_since = watermark − RECONCILE_OVERLAP_S`;
  - each payment inserts `payment.created:<id>`, plus `payment.reversed:<id>` when
    `status = reversed`, with synthetic event IDs `recon:<type>:<pay_id>`,
    `occurred_at = received_at` or `reversal.reversed_at`, and `arrival_path = reconciliation`;
  - facts already recorded by webhook are not added again; a second identical run adds nothing;
  - the cursor is saved after each page; a run killed mid-walk is marked `failed / interrupted`
    by the next claimant, which resumes from the cursor and ends in the same state as a clean
    run;
  - the watermark becomes the run's start time; failure keeps the cursor and backs off 30 s
    doubling up to the interval, with jitter.
- [X] T049 [P] [US3] Unit spec `api/spec/unit/reconciliation/scheduler_spec.rb`: two schedulers
  never claim the same connection; an expired `reconcile_lease_until` is reclaimable; only
  `active` and `renewal_failing` connections are claimed; `POST /connections/{id}/reconcile`
  sets `next_reconcile_at = now()`, and returns 409 for a connection that isn't active.

  *2026-10-29: T047–T049 were seen failing first: none could load
  (`uninitialized constant Rentsync::Pms::Client` and `Rentsync::Reconciliation`). Choices
  they pin:*
  - *the shared Retry-After block keeps its time (`Rentsync::Clock`) as the value, set by a
    small Lua compare-and-set that keeps the later block;*
  - *a 401 forces one renewal and retries once, so a revoked grant ends in `needs_reauth`
    through the refresh's `invalid_grant`;*
  - *a reconciled `payment.created` takes the payment's own `received_at` as `occurred_at`,
    the same time as the PMS's webhook, so both paths agree;*
  - *after a resumed walk, the watermark is the earliest start since the last success, so pages
    read before an interruption can't hide later updates;*
  - *409 applies to connections that are not reconciled: `needs_reauth` and `disconnected`.
    `renewal_failing` is still reconciled.*

### Implementation for User Story 3

- [X] T050 [US3] Migration `api/db/migrations/004_reconciliation.rb`: `reconciliation_runs`
  with every column in data-model.md; `trigger` in `schedule|manual|initial`; `outcome` in
  `succeeded|failed` or null while running.
- [X] T051 [US3] `api/lib/rentsync/pms/client.rb`: `Net::HTTP` on `PMS_API_URL`, the shared
  bucket (`api/lib/rentsync/rate_limit/token_bucket.lua`), `blocked_until`, and backoff.
  Passes T047.
- [X] T052 [US3] `api/lib/rentsync/reconciliation/run.rb`. Passes T048.
- [X] T053 [US3] `api/lib/rentsync/reconciliation/scheduler.rb`, registered as a worker job,
  and the "Reconcile now" route. Passes T049.

  *2026-10-29 (T050–T053):*
  - *Migration 004 adds the foreign key from `raw_events` that 003 promised, and
    `pms_connections.reconcile_requested_at` (data-model.md updated), so a run can be named
    `manual` and a press during a run isn't lost.*
  - *The Reconcile now button sits on `/connections` and redirects there until the health
    page exists (US4).*
  - *Mutation checks, each caught: dropping `SKIP LOCKED`, dropping the status filter, not
    saving the cursor, not reading the shared block, and not setting it.*

- [X] T054 [US3] Extend the daily purge (T035) to delete `webhook_receipts` older than 90 days.
  Spec: raw events are untouched and the job runs once a day across two workers.

  *2026-10-29: the two new examples were seen failing first. "Across two workers" uses two job
  instances against one lease; the lease spec from T035 already covers a held lease. Raw events
  are kept even when the receipts that point to them are purged.*

- [X] T055 [P] [US3] `api/bin/compare_with_pms [--wait <s>] [--reconcile]`: lists the mock's
  true events (`GET /admin/events`) for connected operators, optionally triggers and waits for
  one reconciliation, lists RentSync's (`/admin/raw_events`), and prints missing, duplicated and
  per-type counts. It exits non-zero on any missing or duplicated fact.

  *2026-10-29: runs in the `api` container. Payment facts are compared by business key, because
  reconciled facts have synthetic IDs. Lease events are compared only when the mock delivered
  them to RentSync's client, because reconciliation never fetches them (R5). RentSync's side is
  read from the database, not over `/admin/raw_events`, since the tool runs where the database
  is. Checked live after the first full backfill: 893 `payment.created` and 632
  `payment.reversed`, with 0 missing and 0 duplicated, exit 0.*

- [X] T056 [US3] Metrics `rentsync_reconciliation_runs_total{result}`,
  `rentsync_pms_requests_total{status}`, `rentsync_pms_rate_limit_waits_seconds_total` and
  `rentsync_token_renewals_total{result}`.

  *2026-10-29: `reconciliation_metrics_spec.rb` was seen failing first (4 of 5). The runs
  counter passed at once, because T052 already counted it. Renewal results are `renewed`,
  `needs_reauth` and `failed`. The PMS request status is the HTTP code, or `timeout`.*

- [X] T057 [US3] Write `docs/adr/0009-postgres-claimed-background-work.md` from research R2,
  including when to revisit Sidekiq.

**Checkpoint**: quickstart §3 (full) and §4 pass locally.

---

## Phase 6: User Story 4 - See connection health (Priority: P2)

**Goal**: one page answers "is the data coming in?"

**Independent Test**: produce a known mix of good, duplicate and bad deliveries and one
reconciliation, then compare the health page with `/admin/receipts`.

### Tests for User Story 4 (write first; they must fail) ⚠️

- [ ] T058 [P] [US4] Unit spec `api/spec/unit/health/report_spec.rb`: with fixed rows, the
  report returns the Health schema in contracts/openapi.yaml exactly:
  - received total, by path and by type; duplicates and rejections over 90 days, by reason;
  - `last_successful_sync_at` is the later of the newest webhook-recorded event and the newest
    successful run;
  - the last run with `last_succeeded_at` and `next_due_at`;
  - at most 50 recent rejections, with only time, reason, event type and event ID;
  - `unknown_operator` receipts never appear in any operator's report.
- [ ] T059 [P] [US4] Request spec `api/spec/requests/health_spec.rb`: the HTML and JSON views
  agree; operator B gets 404 for operator A's connection; failed runs show their error code and
  last success (US4 AC3); no payload content, header value or tenant name appears in the HTML.

### Implementation for User Story 4

- [ ] T060 [US4] `api/lib/rentsync/health/report.rb`: SQL aggregates, scoped by operator.
  Passes T058.
- [ ] T061 [US4] The health page and `/v1/connections/{id}/health` JSON in
  `api/lib/rentsync/web/` and `api/lib/rentsync/api/`. Passes T059.

**Checkpoint**: all four stories work locally; quickstart §2–§4 pass.

---

## Phase 7: Deploy to staging and production (FR-025)

**Goal**: RentSync runs beside the mock PMS on both environment hosts and ships with every
release.

**Independent Test**: quickstart §5–§6.

### Tests (write first; they must fail) ⚠️

- [ ] T062 [P] Extend `infra/host/test/render_env_test.sh`: an environment host without
  `rentsync/encryption_keys`, `rentsync/operator_seed_password` or `rentsync/session_secret`
  fails, naming the parameter, never its value; with them, the env file contains every key in
  contracts/host-changes.md "Rendered environment additions", with
  `RENTSYNC_DATABASE_URL` ending in `rentsync_<deployment id with underscores>`.
- [ ] T063 [P] Extend the `rentsync-deploy` tests (`infra/host/test/`): it pulls both images at
  one tag, runs both setups, and succeeds only when both `/healthz` report the new version over
  the Compose network; if the API is unhealthy, **both** roll back to the previous tag.
- [ ] T064 [P] Terraform tests (`infra/terraform/environment/tests/`, `infra/terraform/shared/tests/`):
  the three write-only `rentsync_*` variables and their `_version` companions produce SSM
  SecureString parameters under `<deployment path>/rentsync/`; `app_hostname` reaches host.env;
  the `rentsync/api` ECR repository has immutable tags and the mock's lifecycle policy; the
  GitHub release role may push to it and host roles may pull from it.

### Implementation

- [ ] T065 `infra/terraform/environment`: `app_hostname` and the `rentsync_*` variables
  (validation: encryption keys match `^[a-z0-9]+=[A-Za-z0-9+/]{43}=(,[a-z0-9]+=[A-Za-z0-9+/]{43}=)*$`,
  seed password ≥ 16 characters, session secret ≥ 32 URL-safe characters, none equal to the
  `.env.example` values), SSM parameters via the write-only pattern (ADR-0007), and host.env.
  Update `specs/002-aws-deployment/contracts/workspace-variables.md`. Passes T064.
- [ ] T066 `infra/terraform/shared`: the `rentsync/api` ECR repository and the IAM additions.
  Passes T064.
- [ ] T067 `infra/host/bin/rentsync-render-env`: require and render the new keys. Passes T062.
- [ ] T068 `infra/host/compose.env.yaml` (`api` with `mem_limit: 256m`, `api_worker` with
  `mem_limit: 192m`, `${API_IMAGE}`, only the variables each needs), `infra/host/Caddyfile.env`
  (the `{$APP_HOSTNAME}` site block with `respond /metrics* 404` and `reverse_proxy api:4002`),
  and `infra/otel/collector.yaml` (scrape `api:4002` and `api_worker:4003` at the same interval
  variable). Validate the Collector config with `otelcol validate` as before.
- [ ] T069 `infra/host/bin/rentsync-deploy`: both images, both setups, both health checks,
  joint rollback. Passes T063.
- [ ] T070 `.github/workflows/release.yml` builds and pushes both images with the commit SHA;
  `deploy-to.yml`'s external check also verifies `APP_URL`'s `/healthz` version;
  `bootstrap-github.sh` sets `APP_URL` per GitHub Environment (with its bootstrap test updated).
- [ ] T071 CI job `ingestion-e2e` in `.github/workflows/ci.yml` (research R17), modelled on
  `telemetry-smoke`: start mock and API, `bin/setup` both, run `bin/connect_operator` on the
  runner, set every chaos rate (quickstart §3 values), run `month_end_burst`, then
  `bin/compare_with_pms --wait 180 --reconcile`, which must exit 0. On failure, dump
  `docker compose logs`.
- [ ] T072 **🧑 OPERATOR**: add A records `app-staging.rentsync.org` and `app.rentsync.org` to
  the environments' Elastic IPs and wait until they resolve; set the new workspace variables
  (contracts/host-changes.md) in `rentsync-dev-staging` and `rentsync-prod-us`; apply
  `rentsync-shared-us` (confirm), then `rentsync-dev-staging`, then `rentsync-prod-us` (confirm).
  The A records come **before** the first release that includes the API (quickstart §5).
- [ ] T073 After merge, run quickstart §5 steps 2–5 and §6 against staging, then prod
  (approval needed: **🧑 OPERATOR**), including SC-006's p95 from `rentsync_webhook_ack_seconds`
  and SC-002's 24-hour check (step 5). Record results in the build log.
- [ ] T074 Run quickstart §5 step 6 (memory gate). Size up **only on proven need** as research
  R14 defines it, which is the operator's decision. Record the numbers and the decision. This
  needs host access through the RentSync AWS account, so it is **🧑 OPERATOR** unless the
  operator has confirmed the AWS CLI profile in use.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T075 [P] Write `docs/adr/0010-server-rendered-pages-until-dashboard.md` (research R12) and
  `docs/adr/0012-pms-credential-encryption-and-registration.md` (research R8, R9).
- [ ] T076 [P] Update `docs/deploy/runbook.md`:
  - rotating the RentSync encryption keys (add a key, apply, wait for the lazy re-encryption,
    remove the old key);
  - reconnecting operators after a mock `/admin/reset`;
  - reading the health page;
  - replaying lost webhooks (`POST /admin/replays` on the mock) and forcing a reconciliation.
- [ ] T077 [P] Update `docs/deploy/production-differences.md`: one Postgres role shared by both
  services; the admin-API registration shortcut; server-rendered pages; one host per
  deployment running both services.
- [ ] T078 [P] Update `README.md`: what RentSync does now, the `app-*` URLs, the local
  quickstart, and links to this feature's spec and ADRs.
- [ ] T078a [P] Add `/api` to `.github/dependabot.yml` for the `bundler` and `docker`
  ecosystems, on the same schedule and grouping as `/mock_pms` (constitution, Dependency
  maintenance).
- [ ] T079 Run quickstart §1–§4 and §7 locally in full; fix anything found through tasks above.
- [ ] T080 Run the full suites (`api` and `mock_pms` rspec and rubocop, terraform fmt, validate
  and test, shellcheck, `infra/test/run.sh`, build-log check), then open the PR from
  `003-pms-ingestion` and write the session entry into its slot:
  `ruby bin/build-log fill <pr> entry.md`.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (1)** → **Foundational (2)** → the user stories.
- **US1 (3)** comes first: US2's live checks need a connection, although US2's unit and
  request specs use factory-built connections and can start right after Phase 2.
- **US2 (4)** before **US3 (5)**: reconciliation shares raw events and business keys (R4).
- **US4 (6)** needs the receipts (US2) and runs (US3).
- **Deploy (7)** needs all four stories. T072 (operator) can happen any time before the first
  release that includes the API.
- **Polish (8)** last; T080 closes the feature.

### Story completion graph

```text
Setup → Foundation → US1 ─┬─► US2 ─► US3 ─► US4 ─► Deploy ─► Polish
                          └─(unit/request specs of US2 may start in parallel)
```

### Order within each phase

Tests (seen failing) → migrations → models and domain code → routes and pages → scripts →
metrics → ADR.

### Parallel opportunities

- Phase 1: T002, T003, T004, T008.
- Phase 2: T010, T011 together; then T012, T013, T014, T019.
- US1: T025–T028 (four specs, different files).
- US2: T036–T039; then T041 and T044.
- US3: T047–T049; T055 alongside T052.
- US4: T058, T059.
- Deploy: T062–T064.
- Polish: T075–T078a.

## Parallel Example: User Story 2

```text
Write and see fail, in parallel:
  T036 signature_spec.rb
  T037 envelope_spec.rb
  T038 recorder_spec.rb
  T039 webhook_to_raw_event_spec.rb
Then: T040 migration → T041 signature/envelope [P with T044] → T042 recorder → T043 receiver
```

## Implementation Strategy

### MVP first (User Story 1)

Phases 1–3 give an operator a working, self-renewing PMS connection: the base everything else
needs. Stop and run quickstart §2.

### Incremental delivery

1. US1: connect (MVP).
2. US2: exactly-once webhook ingestion. Demo: chaos on, zero duplicates.
3. US3: reconciliation. Demo: lost webhooks recovered, rate limit respected.
4. US4: the health page.
5. Deploy: live on staging and prod, with the memory gate.

Each increment is committed with green tests; the PR is opened at the end (T080), or earlier as
a draft.

## Notes

- Never weaken a test to make it pass; if one looks wrong, stop and log it in the PR's
  build-log slot (Constitution III).
- Any AWS CLI use needs the operator's confirmation that the active profile is the RentSync
  AWS account (the local default profile is not).
