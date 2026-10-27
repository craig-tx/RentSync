# Phase 0 Research: Mock Property Management System (PMS)

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-10-20

Each entry records the decision, why it was chosen, and the alternatives that were rejected.
The stack baseline comes from section 3 of `rentsync-speckit-kickoff.md`, which says the mock
PMS is a separate small Ruby service in `/mock_pms` with its own database. Entries marked
**ADR** are significant enough to need an ADR in `docs/adr/` during implementation
(Constitution IX).

---

## R1. Web framework

- **Decision**: Grape mounted on Rack and served by Puma. One Grape app serves the JSON API, the
  OAuth token endpoint, and the admin API. The operator approval page is rendered as HTML from
  a Grape endpoint using stdlib ERB.
- **Rationale**: This matches the main `/api` service (also Grape), so the project has one set
  of request and validation patterns. The approval page is one form, so it doesn't justify a
  second framework.
- **Alternatives considered**: Sinatra handles HTML more naturally, but it would mean two web
  frameworks in one repo. Roda and Hanami are less familiar and add nothing here.

## R2. Persistence

- **Decision**: PostgreSQL 16 through Sequel, using a dedicated database (`mock_pms`) on the
  shared Postgres server. Schema changes use Sequel migrations in `mock_pms/db/migrations`.
- **Rationale**: The kickoff requires the mock PMS to have its own database. Postgres gives
  `FOR UPDATE SKIP LOCKED` for the delivery queue (R6), unique constraints for single-use codes,
  and `jsonb` for event payloads.
- **Alternatives considered**: SQLite is simpler but doesn't match the main service and has no
  `SKIP LOCKED`. A separate schema in the RentSync database risks accidental cross-access
  between the mock and its consumer.

## R3. OAuth 2.0 authorization server — **ADR**

- **Decision**: A small authorization server written for this project. It supports:
  - the `authorization_code` grant (with optional PKCE S256),
  - the `refresh_token` grant with rotation,
  - client authentication with `client_secret_basic` or `client_secret_post`.

  Codes, access tokens, and refresh tokens are opaque random strings of 32 bytes or more.
  Only their SHA-256 digests are stored.
- **Rationale**: The flow needed is narrow: one grant type plus refresh, one scope. The main
  OAuth server gem, Doorkeeper, requires Rails, which the kickoff rules out. Writing it directly
  also keeps edge-case behavior explicit and testable: code reuse, refresh reuse, and expired
  versus invalid tokens.
- **Alternatives considered**: Doorkeeper requires Rails. `rack-oauth2` provides building blocks
  but is mainly client-side and still leaves the state machine to write. JWT access tokens
  would make revocation (FR-007) non-immediate unless a lookup is added anyway, so opaque
  tokens are simpler.
- **Details**:
  - Codes live 60 seconds and are single-use. A unique digest plus a `used_at` column enforce
    this.
  - Access tokens default to 300 seconds (`ACCESS_TOKEN_TTL`). Refresh tokens default to 30
    days.
  - When a refresh token is used, it is marked `used_at` in the same transaction that issues
    the new pair. Reusing it returns `invalid_grant`. The grant is not revoked on reuse,
    because the spec asks only for rejection.
  - Error responses follow RFC 6749 and RFC 6750. An expired token returns
    `401` with `WWW-Authenticate: Bearer error="invalid_token", error_description="token expired"`.
    An unknown or revoked token uses `error_description="token invalid"`. This satisfies FR-006.

## R4. Operator sign-in and secrets at rest

- **Decision**:
  - Operator passwords are hashed with bcrypt.
  - Client secrets are hashed with SHA-256 and compared in constant time. They are random and
    high-entropy, so a slow hash adds nothing.
  - Webhook signing secrets are stored as given, because the mock has to sign with them.
- **Rationale**: Anything the mock only verifies is stored one-way. The signing secret must be
  usable, so it cannot be hashed. That is acceptable here: the mock is a local test harness,
  all its secrets are synthetic, and they live in a database that is never deployed to
  production. Constitution VII (v1.1.0) says a system that only *verifies* the tokens it issued
  MUST store one-way hashes, and the mock does exactly that for codes, access tokens, and refresh
  tokens. The encryption requirement applies to tokens a system must present again, which is
  RentSync's stored PMS tokens in feature 002. VII sets no at-rest rule for webhook signing
  secrets.
- **Alternatives considered**: Encrypting the signing secret with a key from the environment
  adds key management to a test harness with no threat model that needs it. Rejected, and noted
  here so the choice is visible.
- **Dependency**: `bcrypt` is the standard password-hashing gem, and nothing in the stdlib
  replaces it.

## R5. Seed data and determinism

- **Decision**: A seed generator driven by two inputs: `SEED` (an integer, default `42`) and
  `SEED_ANCHOR_DATE` (default: today's date, recorded in the database when seeding runs). It
  uses one `Random.new(SEED)` instance and built-in word lists for synthetic names and streets.
  Output depends only on these two inputs.
- **Rationale**: FR-013 and SC-002 require identical data for the same seed. "12 months ending
  in the current month" would change from day to day unless the anchor is an explicit input.
  Tests pin both inputs.
- **Alternatives considered**: The Faker gem can be seeded, but its output changes when its
  version changes, which breaks byte-for-byte reproducibility across upgrades. It is also a
  dependency added only for names. Rejected.
- **What makes the seed reproducible**:
  - **Public IDs**: every seeded row, including seeded events, takes its public `id` from the
    seeded RNG, not from `SecureRandom`. Rows created later by scenarios or admin calls use
    random IDs.
  - **Timestamps**: `created_at`, `updated_at`, `received_at`, `occurred_at` and similar fields
    on seeded rows come from the simulated history anchored on `SEED_ANCHOR_DATE`. The wall
    clock is never used.
  - **Sequences**: `bin/reseed` and `/admin/reset` run `TRUNCATE … RESTART IDENTITY CASCADE`
    before regenerating, so `seq` values come out the same too. They don't affect the digest
    anyway.
  - **Operator passwords** are fixed, derived from the operator's login (for example
    `<login>-pass`) and printed by `bin/seed_report`. `password_digest` uses a random bcrypt
    salt, so it is **left out** of the digest.
  - **`data_digest`** is the SHA-256 of a canonical JSON dump of the `/v1`-visible fields of
    operators (without `password_digest`), properties, tenants, leases, charges, payments
    (including applications and reversals), and seeded events. Within each table, rows are
    ordered by `id`. Keys are sorted, and timestamps are written as UTC ISO 8601 with second
    precision. `seq` and every OAuth, delivery, and harness table are excluded.
- **Profile** (the target mix; the tasks pin exact numbers):
  - Operators: 3, with property counts of about 25, 15, and 10.
  - Properties and leases: 50 properties and 60 leases. Some properties have had two tenants
    in the window.
  - Monthly payment behavior:
    - about 70% paid on time,
    - about 15% paid late (by 3, 7, 12, or 20 or more days),
    - about 8% partial payments (half later completed, half never completed),
    - about 3% NSF reversals, each followed by a repayment or left unpaid. At least one reverses
      a partial payment, for its full amount,
    - the rest unpaid.
  - Move-outs: 4 tenants move out mid-lease.
  - Fees: late fees are charged on late months.
- **Event history**: seeding also writes the `events` that this history would have produced,
  with `occurred_at` set to historical times. It writes no deliveries. Events can be replayed
  later, which gives feature 002 a back-fill path to test.

## R6. Webhook delivery mechanism — **ADR**

- **Decision**: A transactional outbox in Postgres. A business change, its `events` row, and its
  `deliveries` rows (one per subscribed client with an active grant) are written in one
  transaction. A separate worker process (`bin/delivery_worker`) then:
  1. polls every second for due deliveries (`scheduled_at <= now()`), claiming them with
     `FOR UPDATE SKIP LOCKED`;
  2. sends each one over HTTP using `Net::HTTP` from the stdlib;
  3. records a `delivery_attempts` row;
  4. on a failure, reschedules the delivery with backoff.
- **Rationale**:
  - Delays and reordering (R7) become a matter of setting `scheduled_at`.
  - Retries survive restarts.
  - The delivery log (FR-020) is ordinary rows in the database.
  - A replay is a new `deliveries` row for an existing event.
  - Delivery state stays in Postgres, alongside the events it delivers. The mock does use
    Redis, but only for rate limiting (R8).
- **Alternatives considered**: Sidekiq with Redis is what the main backend uses. Its
  scheduled-job sets are harder to inspect for chaos verification than rows in a table, and
  keeping delivery state in Postgres means an event and its deliveries are written in one
  transaction.
  An in-process thread pool would lose deliveries on restart and make the delivery log
  incomplete.
- **Delivery semantics**: at-least-once. If the worker crashes after the HTTP send but before
  recording the outcome, the delivery is retried. That matches real PMS vendors, and the
  consumer's deduplication (feature 002) is designed for it.
- **Retry schedule**: attempt *n* (counting from 1) is retried after `RETRY_BASE_SECONDS * 2^(n-1)`
  plus or minus 10% jitter. `RETRY_BASE_SECONDS` defaults to 2 and `MAX_ATTEMPTS` to 8. Tests
  use a base of 0.01. After the last attempt the delivery is marked `exhausted` and can still
  be replayed.
- **Success**: any 2xx response within 10 seconds. Anything else, including timeouts and
  connection errors, is a failure.

## R7. Chaos decisions and reproducibility

- **Decision**: chaos uses counter-based randomness stored in the database, so no process keeps
  RNG state in memory.
  - Delivery chaos is decided **when the delivery is created**. The decision is stored on the
    row (`deliveries.chaos` jsonb), and the worker only carries it out.
  - `chaos_settings` holds `seed` and the rates. A separate table, `chaos_counters`, has one row
    per stream (`delivery`, `api`).
  - Each decision takes the next counter value with
    `UPDATE chaos_counters SET value = value + 1 WHERE stream = $1 RETURNING value`,
    inside the same transaction that creates the delivery.
  - The random value is the first 8 bytes of
    `HMAC-SHA256(key = seed, data = "<stream>:<counter>:<field>")`, read as an unsigned
    integer and divided by 2^64. This gives a uniform number in [0, 1).
    - `stream` is `delivery` or `api`.
    - `field` names the decision, for example `duplicate`, `reorder`, `reorder_hold`,
      `delay`, `delay_s`, `malform`, `malform_kind`, or `server_error`.
  - The row lock taken by the counter `UPDATE` serializes concurrent draws **within a stream**,
    whether they come from different Puma threads, the worker, or `bin/*` scripts. Each stream
    has its own row, so an API draw never waits on an open delivery transaction, such as a
    month-end burst creating dozens of deliveries. Delivery draws inside one scenario still run
    one at a time. That is intended: it is what keeps them deterministic.
  - `PUT /admin/chaos` and `/admin/reset` set both counters back to 0.
  - API chaos (injected 500s) works the same way on the `api` stream. It runs only when
    `server_error_rate > 0`, so normal operation adds no database write per request.
- **Rationale**: FR-026 requires that the same seed and the same sequence of actions produce
  the same decisions. Decisions depend only on `(seed, counter, field)`. The result is the same
  whichever process or thread draws, survives restarts, and leaves nothing in memory that
  could drift. Two separate streams mean API traffic cannot shift the delivery sequence.
  Persisting each decision on its delivery row means the worker's timing cannot change the
  outcome either.
- **How each effect is applied and measured** (for SC-005, measured over N ≥ 1,000 events):

  | Effect | Applied as | Measured as |
  |---|---|---|
  | Duplicate (rate D) | A second delivery row for the same event and client, `chaos.duplicate_of` set | Share of events with more than one successful delivery (excluding replays) |
  | Out-of-order (rate O) | The delivery is held for a random 2–10 s (`chaos.reorder_hold_s`), so later events overtake it | Share of deliveries flagged `reordered` that a later-occurring event for the same client overtook |
  | Delay (rate L, range a–b s) | `scheduled_at += rand(a..b)` | Share of deliveries flagged `delayed`, each with its observed lag inside the range |
  | Malformed (rate M) | `chaos.malform` set to one of `truncate` (body cut in half), `drop_field` (`data` removed), or `bad_type` (`occurred_at` set to a number). The signature covers the bytes actually sent | Share of deliveries whose body fails to parse or fails the envelope schema |
  | Server error (rate E) | Rack middleware returns `500` before routing for `/v1/*` data requests only. OAuth and admin endpoints are never affected | Share of `/v1/*` responses that are injected 500s |

  Out-of-order is measured from the flagged decisions and checked against the order the
  receiver saw. Because a flagged delivery can end up overtaken by nothing when traffic is
  sparse, the verification script produces a dense burst.
- **Alternatives considered**:
  - **Deciding at send time in the worker**: outcomes depend on timing and on the number of
    workers, so runs are not reproducible.
  - **In-memory `Random.new(seed)` streams**: each process gets its own stream, a restart
    resets it, and concurrent threads interleave their draws. That breaks FR-026 as soon as a
    second process or a restart is involved.
  - **A reorder buffer that shuffles batches**: more complex, and it couples events from
    different clients.

## R8. Rate limiting — **ADR**

- **Decision**: A token bucket per client, stored in **Redis 7** and updated atomically by one
  Lua script, called from Rack middleware with `EVALSHA`. The web process keeps no
  rate-limit state of its own.
  - **Bucket**: capacity is the client's `rate_limit_per_minute`, or `RATE_LIMIT_PER_MINUTE`
    (default 60) if the client has none. Tokens refill continuously at capacity / 60 000 per
    millisecond.
  - **Storage**: each bucket is a hash under `mock_pms:rl:<client_id>` with fields `tokens`
    and `ts_ms`. The script sets `PEXPIRE` to the time needed for a full refill plus 1 s, so an
    idle client's key expires and that client starts with a full bucket.
  - **Script**: in a single atomic step, the script:
    1. reads the bucket,
    2. adds the tokens that have built up since `ts_ms`, up to capacity,
    3. then either takes one token, or works out how long until the next one is available,
    4. writes the bucket back.

    It returns `{allowed, retry_after_ms, remaining}`.
  - **Clock**: the script reads Redis `TIME`, so every web process measures time from one
    source. Tests pass `now_ms` as an optional argument instead, which makes timing
    deterministic without sleeping.
  - **429 response**: when the bucket is empty, the request gets `429` with `Retry-After`
    set to `ceil(retry_after_ms / 1000)`, and never less than 1.
  - **Key**: the bucket is keyed by the client ID that the access token resolves to.
  - **If Redis is unavailable**, the limiter **fails closed**: `/v1/*` requests get
    `503 {"error":{"code":"rate_limiter_unavailable"}}`, and `/healthz` reports Redis as down.
    Failing open would quietly switch off the behavior this harness exists to demonstrate.
- **Rationale**:
  - All bucket state lives in Redis, so the web tier is stateless. The limit stays exact
    however many Puma workers or containers serve requests.
  - The single-process restriction on the web service is gone.
  - Redis is already part of the project stack (Sidekiq in the kickoff §3 plan, ElastiCache in
    feature 007), so this adds no new kind of infrastructure, just a service the mock now uses.
  - The Lua script keeps the read, refill, take, and write steps atomic without
    `WATCH`/`MULTI` retry loops.
- **Alternatives considered**:
  - **In-process bucket guarded by a `Mutex`**: exact and dependency-free, but it ties the web
    service to a single process. This was the earlier design, replaced at the user's request.
  - **Postgres counter table**: adds a database write to every API request, and a fixed window
    allows bursts at the window boundary.
  - **Rack::Attack backed by Redis**: it only offers fixed-window throttles, so `Retry-After`
    would be the time to the end of the window rather than an exact token-bucket wait. It also
    adds a gem the 25-line script replaces.
  - **Redis `INCR` + `EXPIRE` fixed window**: simpler, but it allows bursts of twice the limit
    across a window boundary. That's less realistic, and it makes SC-006's "throttled on the
    first excess request" depend on where the window falls.
- **Process model**: Puma still defaults to a single process (`workers 0`) with threads,
  because that is plenty for a harness. Correctness no longer depends on that: running more
  workers or containers is safe. Request metrics are also aggregated in Redis (R12), so one
  scrape of any instance shows the totals for every instance.
- **Scope**: the limiter applies to `/v1/*` data endpoints only. The token endpoint, the
  approval page, admin, health, and metrics are exempt, which satisfies FR-022. Scenario
  activity never touches the limiter.

## R9. Pagination

- **Decision**: Keyset pagination on the immutable internal `seq` (bigint identity), in
  ascending order.
  - The request takes `limit` (default 50, maximum 200) and an opaque `cursor`, which is the
    URL-safe base64 of the last `seq` returned.
  - The response returns `next_cursor`, or `null` on the last page.
  - Filters (`updated_since`, `from`, `to`, and the lease, tenant, or property ID) only narrow
    the results. They never change the sort order.
- **Rationale**: Ordering on an immutable, increasing key means records that existed when paging
  began are never skipped or repeated. Inserts land after the cursor (spec edge case). If
  `updated_at` were the sort key, rows would move while a client is paging.
- **Alternatives considered**: Offset pagination skips and repeats rows under inserts. Sorting by
  `(updated_at, id)` reorders rows when they are updated.
- **Public identifiers**: each resource has a prefixed public ID (`prop_`, `ten_`, `lease_`,
  `chg_`, `pay_`, `evt_`, `dlv_`) followed by 20 base32 characters. Seeded rows draw these
  characters from the seed RNG (R5); all other rows use `SecureRandom`. `seq` is never
  exposed except inside the cursor.

## R10. Webhook signature scheme

- **Decision**: Every delivery is an HTTP `POST` with a JSON body and these headers:
  - `PMS-Signature: t=<unix_seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw_body>")>`
  - `PMS-Event-Id`, `PMS-Event-Type`, `PMS-Delivery-Id`, `PMS-Delivery-Attempt`
  - `X-Correlation-Id`
- **Rationale**: Signing the timestamp lets the receiver reject replayed or stale requests
  (feature 002 chooses the tolerance window). This is the widely understood Stripe-style
  scheme, and it needs only the stdlib (`OpenSSL::HMAC`).
- **Alternatives considered**: A signature over the body alone gives no replay protection.
  JWS adds dependencies and complexity for no gain here.
- **Correlation**: each event stores the `correlation_id` of the request or scenario run that
  caused it. Every delivery sends it as `X-Correlation-Id`, so RentSync can carry it from the
  webhook through its jobs to the ledger (Constitution VI).

## R11. Admin authentication and idempotent admin actions

- **Decision**:
  - Admin endpoints (`/admin/*`) require `Authorization: Bearer <ADMIN_TOKEN>`, compared in
    constant time.
  - Admin `POST` requests that cause side effects (trigger a scenario, replay, revoke, reset)
    accept an `Idempotency-Key` header. The first response for a key is stored in
    `admin_idempotency_keys`. A repeat with the same key and the same request body returns the
    stored response without running the action again. The same key with a different body
    returns `422`. If the same key arrives while the first request is still running, the
    response is `409 idempotency_in_progress`. If the handler fails, its key is released.
  - **Exception**: `POST /admin/clients` does not support `Idempotency-Key`. Its response carries
    the one-time `client_secret`, and storing that response would keep the secret in plaintext
    in `admin_idempotency_keys`, contradicting R4. A retried registration just creates a second
    client, which is harmless in a harness.
  - `admin_idempotency_keys` is kept across `/admin/reset`, so a retried reset finds its own key
    and doesn't reseed a second time.
- **Rationale**: Constitution II requires every outbound side effect to be safe to retry, and a
  demo script that retries "trigger month-end burst" must not run it twice. A single shared
  secret is enough for a local harness (spec Assumptions).
- **Alternatives considered**: Making each admin action naturally idempotent doesn't work for
  scenarios, because each run is meant to create new payments. An explicit key is the only
  correct option.

## R12. Observability

- **Decision**:
  - **Logging**: one JSON object per line on stdout, from the stdlib `Logger` with a JSON
    formatter. Field names follow OpenTelemetry semantic conventions, so the Collector can map
    them without renaming anything (R16). Every line has:
    - `timestamp` (RFC 3339, UTC), `severity_text`, and `body` (the message);
    - **`service.name`**: `mock_pms-web`, `mock_pms-worker`, or `mock_pms-tool`;
    - `service.version` (the git SHA baked into the image), `deployment.environment`, and
      `service.instance.id` (the container hostname);
    - **`code.function.name`**: the fully qualified method that wrote the log line, for example
      `MockPms::Delivery::Worker#deliver` or `MockPms::Seed::Generator.run`;
    - `code.file.path` and `code.line.number`;
    - `correlation_id`, plus any fields specific to the event.
  - **How the method name is captured**: code never writes the method name itself. Classes
    include a `MockPms::Logging::Loggable` mixin that provides `log.info(msg, **fields)` and
    the other levels. The mixin:
    - reads `caller_locations(1, 1).first` (one frame, so the cost is small);
    - takes `base_label` from it. That is the bare method name, and calls from inside blocks
      resolve to their enclosing method;
    - adds the receiver's class name, joined with `#` for instance methods or `.` for class
      methods.

    This works the same on Ruby 3.3 and 3.4, even though Ruby 3.4 changed how backtrace labels
    are formatted. Request-level lines, such as the access log, report the Grape endpoint
    instead, for example `MockPms::API::V1#GET /v1/payments`. Any log line that doesn't come
    through the mixin is a lint failure: a RuboCop rule bans `Logger#info` and similar calls
    outside `logging.rb`.
  - **Correlation ID**: taken from an incoming `X-Request-Id` or `X-Correlation-Id` header, or
    generated. A redaction filter masks token, secret, password, `name`, `email`, `phone`, and
    `amount_cents` fields.
  - **Metrics**: `GET /metrics` serves Prometheus text format, written by hand with no
    dependency. Every instance returns the same totals for the whole cluster, so Prometheus
    needs only one scrape target (Constitution X). It reports:
    - **Request counts and latency**, by route template, method, and status. These are
      buffered in each process and flushed to Redis, as described below.
    - **Worker delivery-send latency**, buffered and flushed the same way from the worker.
    - **Delivery counts** by outcome, attempts, and chaos flag, plus queue depth. These are
      read from database aggregates (`deliveries` and `delivery_attempts`), which already hold
      the true values.
    - **Worker heartbeat age**.
  - **How metrics are buffered and flushed (stateless, no locks)**:
    - **Buffer**: each process keeps a delta buffer in memory, guarded by an in-process
      `Mutex`. It holds counter increments and histogram buckets: fixed `le` bounds of 5 ms to
      10 s, plus `_sum` and `_count`. The process does not keep totals.
    - **Flush**: a background thread wakes every `METRICS_FLUSH_INTERVAL_S` (default 5 s).
      1. Under the `Mutex`, it swaps the buffer for an empty one. This takes O(1) time, so
         request threads never wait on Redis.
      2. It sends every delta in one `MULTI`/`EXEC`, using `HINCRBY` for counters and
         histogram buckets and `HINCRBYFLOAT` for sums.
    - **Redis keys**: one hash per metric family, for example
      `mock_pms:metrics:http_requests_total`. Each field is a canonical label string such as
      `route=/v1/payments|method=GET|status=200`.
    - **No race conditions**: Redis applies each increment atomically, so concurrent flushes
      from any number of instances add up correctly without a distributed lock. A lock would
      only serialize flushes and add new ways to fail: expiry partway through a flush, and a
      stalled holder blocking every other instance.
    - **Failed flush**: if Redis is unreachable, the swapped-out deltas are merged back into
      the live buffer and retried on the next tick. The buffer is capped at 10 000 fields;
      beyond that, new label combinations are dropped and counted in
      `mock_pms_metrics_dropped_total`.
    - **Shutdown**: on graceful shutdown (Puma `on_worker_shutdown` and `at_exit` in the
      worker), the process runs a final flush.
    - **Bounded loss (Constitution X)**: a crash loses at most one flush interval of deltas from
      that process. Totals never go backwards because of a crash.
    - **Counter resets**: `/admin/reset` does not clear metrics. A Redis restart does, and
      Prometheus's `rate()` handles counter resets by design.
    - **Freshness**: scraped values lag real traffic by up to one flush interval.
    - **Labels**: label sets are bounded. Routes are recorded by template (`/v1/{resource}/{id}`),
      never by raw path, so no resource IDs and no personal data reach Redis. A request answered
      by middleware before Grape routes it (429, 503, chaos 500) has no template. Its label comes
      from a static prefix map, for example `/v1/{resource}`, or is `unmatched`.
      `client_id` is allowed as a label on `mock_pms_rate_limited_total`: there are only a few
      clients, and the ID is public and not personal data.
    - **Resource identity**: `/metrics` emits
      `target_info{service_name="mock_pms-web",service_version=…,deployment_environment=…} 1`,
      so scraped series carry `service.version` (Constitution VI; R16).
  - **Health**: `GET /healthz` reports database connectivity, Redis connectivity (a `PING`;
    the rate limiter depends on Redis, see R8), and the worker heartbeat age. The worker updates
    a `worker_heartbeats` row every 5 seconds. The response is `200` when the database and
    Redis are both reachable and the heartbeat is under 30 seconds old, otherwise `503` with
    details.
- **Rationale**: Constitution VI requires metrics and health on every service. This goes beyond
  spec FR-030, which lists only health and logs. Constitution X requires shared state, including
  metrics, to live outside the process. Buffering locally and flushing periodically keeps Redis
  off the request path (no round trip per request), while totals stay correct across instances.
  Because the worker's numbers go through Redis and the database too, the worker doesn't need
  its own HTTP server.
- **Alternatives considered**:
  - **In-process totals per instance** (the earlier design): violates Constitution X, needs one
    scrape target per instance, and loses all history on a restart.
  - **`HINCRBY` on every request**: correct, but it adds a Redis round trip to every request and
    turns any Redis delay into request latency.
  - **Flushing behind a distributed Redis lock** (`SET NX PX`): unnecessary, because increments
    are already atomic. It serializes flushes and adds lock-expiry and stalled-holder failure
    modes.
  - **The `prometheus-client` gem with a shared-file store**: it works only for processes on
    the same host, not across containers.

## R13. Testing approach

- **Decision**:
  - **Unit tests** (RSpec): pure logic with injected clocks and RNGs.
  - **Request tests** (RSpec with Rack::Test): every endpoint, run against a real Postgres test
    database, with each test wrapped in a transaction that is rolled back.
  - **End-to-end delivery test**: starts a throwaway receiver (a Rack app on Puma, on a random
    port, in a thread), creates an event, runs the worker loop, and checks that the delivered
    body and signature can be verified.
  - **Test-first** (Constitution III) applies to:
    - signature generation,
    - the token lifecycle (code reuse, refresh rotation and reuse, expiry versus invalid,
      revocation),
    - pagination stability under inserts,
    - seed determinism (two runs give identical digests),
    - chaos decisions (rates within tolerance for a fixed seed; identical decision sequences
      for the same seed),
    - the retry schedule,
    - admin idempotency,
    - the rate-limit script, run against a real Redis with `now_ms` passed in. The tests cover
      exhausting the bucket, the exact `Retry-After` value, refill, per-client isolation,
      atomicity under concurrent calls, and a 503 (fail closed) when Redis is unreachable.
    - log line shape. The tests check that every line carries `service.name` and the correct
      `code.function.name`, including from instance methods, class methods, and blocks, and
      that redaction runs before a line is written;
    - the metrics flush, tested against a real Redis. The tests check that:
      - deltas from concurrent flushes in several threads and processes sum exactly,
      - a failed flush merges its deltas back and sends them on the next tick,
      - the buffer cap and its dropped counter work,
      - the Prometheus text rendering is correct.
  - **Test isolation**: test runs use their own Redis key prefix (`mock_pms:test:<pid>:`) and
    delete those keys after each example.
  - **Lint**: RuboCop.
- **Rationale**: These are the behaviors that feature 002's correctness depends on. Injecting the
  HTTP transport lets most delivery tests skip the network. The one real end-to-end test
  checks the full path.
- **Alternatives considered**: WebMock adds a dependency and patches `Net::HTTP` globally.
  Injecting a transport plus one real-server test covers the same ground.

## R14. Local runtime

- **Decision**:
  - `mock_pms/Dockerfile` (Ruby 3.3 slim) is used for the web and worker processes and for the
    tool commands.
  - A root `compose.yaml` defines only these services:
    - `postgres` (version 16),
    - `redis` (version 7), used by the rate limiter (R8),
    - `otel-collector` and `openobserve` (the UI on port 5080), for telemetry (R16),
    - `mock_pms` (the web service on port 4001),
    - `mock_pms_worker`,
    - `mock_pms_b`, under the `tools` profile: a second web instance with no host port. It is
      used only to show that the rate limit holds across instances (R8).
    - `receiver`, under the `tools` profile. It runs `bin/test_receiver` bound to
      `0.0.0.0:9999` on the Compose network and writes its JSONL log to a `receiver_logs`
      volume. That volume is also mounted into `mock_pms`, so `bin/chaos_check` can read the
      log.
  - Clients in the demo register `subscriber_url: http://receiver:9999/webhooks`, so
    deliveries never leave the Compose network. No host port mapping or `host.docker.internal`
    is needed, and the same setup works on Linux CI.
  - `.env.example` lists every setting.
  - Feature 007 extends `compose.yaml` to the full stack.
- **Rationale**: Docker is the reliable way to run Ruby and Postgres on the Windows development
  machine. Keeping the compose file to the mock's needs avoids taking over feature 007's scope.

## R15. Continuous integration

- **Decision**: add a minimal `.github/workflows/ci.yml` that runs on every pull request and on
  pushes to `main`. A single job:
  1. starts `postgres:16` and `redis:7` service containers,
  2. sets up Ruby 3.3 with bundler caching,
  3. runs `bundle exec rubocop` and `bundle exec rspec` in `mock_pms/`.

  A second job, **telemetry-smoke**, satisfies Constitution VI's rule that an OTLP backend runs
  in CI:
  1. It runs `docker compose up` for `postgres`, `redis`, `mock_pms`, `mock_pms_worker`,
     `otel-collector`, and `openobserve`.
  2. It runs one scenario.
  3. It queries OpenObserve's search API for:
     - a log with `service.name = mock_pms-worker` and a non-empty `code.function.name`,
     - the `mock_pms_http_requests_total` metric.

  The job fails if either is missing after 60 s.

  Feature 007 extends this workflow with the other services, type checks, agent evals, and
  `terraform plan`.
- **Rationale**: The constitution says CI MUST be green before any merge (Principle III and the
  Workflow section). Feature 001 is merged before feature 002 starts, so its tests need CI
  now. They cannot wait for feature 007.
- **Alternatives considered**:
  - Running the tests only locally until feature 007 would mean merging against a MUST.
  - Running CI through Docker Compose would be slower and adds nothing for a single Ruby
    service.
- **Alternatives considered**: Native Ruby on Windows (RubyInstaller) is possible, but
  `pg` and `bcrypt` native builds are fragile there. It works for anyone who prefers it, but the
  quickstart does not depend on it.

## R16. Telemetry delivery over OTLP (Collector bridge) — **ADR**

- **Decision**: The services don't speak OTLP themselves. An **OpenTelemetry Collector**
  (the `contrib` distribution) collects their standard outputs and sends them on as OTLP/HTTP
  to **OpenObserve**:
  - **Logs**: the `filelog` receiver tails Docker's JSON log files
    (`/var/lib/docker/containers/*/*-json.log`, mounted read-only) and reads only the
    `mock_pms*` containers.
    - Its `container` and `json_parser` operators parse each line.
    - It promotes `service.*`, `deployment.environment`, and `service.instance.id` to resource
      attributes, and keeps `code.*` and `correlation_id` as log attributes.
    - It maps `severity_text` onto the OTLP severity.
  - **Metrics**: the `prometheus` receiver scrapes `http://mock_pms:4001/metrics` every 15 s
    (`METRICS_SCRAPE_INTERVAL`; deployed hosts use 60 s, feature 002 R8).
    One target is enough. Any instance returns totals for the whole cluster (R12), and Compose
    DNS routes the scrape to whichever instance it reaches. `/metrics` emits
    `target_info{service_name="mock_pms-web",service_version="<SERVICE_VERSION>",deployment_environment="<env>"} 1`,
    and the Prometheus receiver turns `target_info` into resource attributes. Every series
    therefore carries `service.name=mock_pms-web` (the same name as the web service's logs),
    `service.version`, and `deployment.environment`, as Constitution VI requires. There is no
    `service.instance.id`, because these series are cluster totals rather than instance-level
    data.
  - **Processing**: the `memory_limiter` and `batch` processors run first. Then a
    `transform`/`attributes` processor deletes any attribute whose key matches the redaction
    list. That is a second line of defense; the services already redact before writing a line
    (Constitution VII).
  - **Export**: the `otlphttp` exporter sends to `http://openobserve:5080/api/default`, with a
    Basic auth header built from `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD` (defined in
    `.env.example`, never committed). Its sending queue retries with backoff. When the queue is
    full, new data is dropped and the Collector's own
    `otelcol_exporter_send_failed_*` metrics count the drops.
  - **Loss bound (Constitution X)**: the sending queue lives in memory (`queue_size: 1000`
    batches) and is not persisted. A Collector crash or restart therefore loses whatever is
    queued at that moment. During an OpenObserve outage, that is at most `queue_size` batches,
    roughly 15 minutes of mock telemetry at harness volumes. While OpenObserve is up, it is a
    few seconds of batches. Nothing is lost from the services themselves: logs stay in Docker's
    files and on stdout, and metric totals stay in Redis and are scraped again next time.
  - **Collector self-monitoring**: the Collector exposes its own metrics on `:8888`. Its
    `prometheus` receiver also scrapes `localhost:8888` as job `otel-collector`, so the
    `otelcol_exporter_send_failed_*`, `otelcol_exporter_queue_size`, and
    `otelcol_processor_refused_*` drop counters reach OpenObserve once it is reachable again.
    They can also be read directly with
    `docker compose exec otel-collector wget -qO- localhost:8888/metrics`.
  - **Field names in OpenObserve**: OpenObserve stores dotted attribute keys with the dots
    flattened to underscores (`service.name` becomes `service_name`, `code.function.name`
    becomes `code_function_name`). **Verified on 2026-10-21 against openobserve v1.0.4 (T101)**.
    Scraped metrics carry `service_name=mock_pms-web`, `service_version` and
    `deployment_environment`, and no instance id. `bin/telemetry_smoke` keeps the field names in
    one constant in case a later version changes them.
  - **Component names**: the Collector (0.162.0) warns that `filelog` and `otlphttp` are
    deprecated aliases, so the config uses `file_log` and `otlp_http`.
- **Rationale**:
  - The OpenTelemetry Ruby metrics and logs SDKs are still pre-1.0 (0.x). Their APIs can change
    between minor releases, and the metrics SDK does not yet implement the whole spec.
    Tracing is the only stable Ruby signal. Keeping the services on stable, standard outputs
    (JSON on stdout and Prometheus text) means they have **no** OpenTelemetry dependencies.
  - Moving to native SDKs later changes only the Collector's receivers.
  - The backend is purely configuration (Constitution VI): changing OpenObserve for another
    OTLP backend means editing one exporter block.
  - Export never touches the request path. If the Collector or OpenObserve is down, the
    services keep running and logs remain on stdout.
- **Alternatives considered**:
  - **Native OTel metrics and logs SDKs in the app**: these 0.x gems risk API churn, and each
    instance would export its own series, which makes the Redis aggregation pointless. Revisit
    once they reach 1.0.
  - **Docker `fluentd` logging driver with the Collector's `fluentforward` receiver**: the
    Docker daemon has to reach the Collector on a published host port, and containers fail to
    start when the Collector is down unless they run in async mode. `filelog` reads files that
    Docker writes anyway.
  - **Services shipping straight to OpenObserve's own ingestion API**: violates the
    vendor-neutral rule in Constitution VI.
- **Versions**: the Collector and OpenObserve images are pinned to exact tags in
  `compose.yaml`, chosen during implementation (at least two weeks old). `latest` is never
  used.
- **Where config lives**: `infra/otel/collector.yaml`. Feature 007 reuses it for AWS by changing
  only the exporter endpoint and credentials.

---

## Resolved unknowns

The Technical Context items are resolved as follows:

- Background processing: R6.
- Rate-limit store: R8.
- Determinism: R5 and R7.
- Secrets storage: R4.
- Metrics: R12.
- Run environment: R14.
- CI gate: R15.
- Telemetry delivery and the backend: R16.

No NEEDS CLARIFICATION items remain.
