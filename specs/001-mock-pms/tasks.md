---

description: "Task list for feature 001: Mock Property Management System (PMS)"
---

# Tasks: Mock Property Management System (PMS)

**Input**: Design documents from `/specs/001-mock-pms/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/openapi.yaml](contracts/openapi.yaml),
[contracts/webhooks.md](contracts/webhooks.md), [quickstart.md](quickstart.md)

**Tests**: These are **required**. Constitution Principle III (non-negotiable) requires
test-first development, and research R13 lists the units it covers. In each phase, the test
tasks come before the implementation tasks they cover. Each test MUST be run and seen to fail
before the matching implementation task starts.

**Organization**: Tasks are grouped by user story. Each story can be implemented and tested
on its own once Phase 2 is complete.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel with other [P] tasks in the same phase (it touches different
  files and doesn't depend on unfinished tasks).
- **[Story]**: the user story the task belongs to (US1–US5, from spec.md).
- All paths are relative to the repository root. Service code lives in `mock_pms/`.

## Conventions for every task

- **Ruby**: Ruby ≥ 3.3, with `# frozen_string_literal: true` at the top of every file. The
  namespace is `MockPms::`.
- **Tests**: RSpec. Request specs use Rack::Test against `MockPms::App`. Database tests run
  inside a transaction that is rolled back afterwards. Redis tests use the key prefix
  `mock_pms:test:<pid>:` and delete their keys after each example (R13).
- **Time and randomness**: never read wall-clock time or `SecureRandom` directly in domain
  code. Use `MockPms::Clock` and `MockPms::Ids` (T014, T015) so tests can inject them.
- **Logging**: always through the `MockPms::Logging::Loggable` mixin (T017). Calling
  `Logger#info` or similar anywhere else is a lint failure (T008).
- **Shared state**: shared state belongs in Postgres or Redis. Every shared write is atomic,
  and there are no distributed locks (Constitution X).
- **Commits**: run `bundle exec rspec` and `bundle exec rubocop` in `mock_pms/` before every
  commit. Both MUST pass.
- **Test integrity**: do not weaken a test to make it pass. If a test looks wrong, stop and
  record it in `docs/ai-build-log.md`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the project skeleton, tooling, the local runtime, and CI.

- [X] T001 Create the directory skeleton from plan.md "Source Code": `mock_pms/{bin,config,db/migrations,lib/mock_pms/{models,api,views,oauth,middleware,events,delivery,chaos,seed,scenarios,admin,metrics,rate_limit,presenters},spec/{unit,requests,integration,fixtures,support}}`, plus `infra/otel/` and `docs/adr/`. Put a `.keep` file in each empty directory.
- [X] T002 Create `mock_pms/Gemfile` with `ruby ">= 3.3"`.
  - Runtime gems: `grape`, `puma`, `sequel`, `pg`, `bcrypt`, `redis`.
  - `:development, :test` group: `rspec`, `rack-test`, `rubocop`.
  - Add no other gems. Each gem is justified in the plan.md Dependencies table (Constitution VIII).
  - Run `bundle lock` to produce `mock_pms/Gemfile.lock`.
- [X] T003 [P] Create `mock_pms/Dockerfile`. One `ruby:3.3-slim` image serves the web process, the worker, and the tools.
  - Install `build-essential` and `libpq-dev`, then run `bundle install`.
  - Copy the app in.
  - `ARG GIT_SHA` sets `ENV SERVICE_VERSION=$GIT_SHA`.
  - Default `CMD ["bundle","exec","puma","-C","config/puma.rb"]`.
  - `EXPOSE 4001`.
- [X] T004 [P] Create `mock_pms/config/puma.rb`.
  - Use `threads` from `PUMA_THREADS` (default 5) and `workers` from `WEB_CONCURRENCY` (default 0), and bind `tcp://0.0.0.0:4001`.
  - Add an `on_worker_shutdown` hook, and an `at_exit` hook for single mode, that call `MockPms::Metrics::Flusher.final_flush!` (implemented in T023). Until T023 exists, guard the call with `defined?`.
  - Add a comment that the web tier is stateless and any worker count is safe (research R8, R12).
- [X] T005 [P] Create `.env.example` at the repository root, containing every setting with a comment. Include no real secrets.
  - Mock settings: `DATABASE_URL=postgres://postgres:postgres@postgres:5432/mock_pms`, `TEST_DATABASE_URL=postgres://postgres:postgres@postgres:5432/mock_pms_test`, `REDIS_URL=redis://redis:6379/0`, `ADMIN_TOKEN=change-me-admin-token`.
  - Seed and token settings: `SEED=42`, `SEED_ANCHOR_DATE=` (empty means today), `ACCESS_TOKEN_TTL=300`, `REFRESH_TOKEN_TTL=2592000`.
  - Limits and delivery settings: `RATE_LIMIT_PER_MINUTE=60`, `RETRY_BASE_SECONDS=2`, `MAX_ATTEMPTS=8`, `METRICS_FLUSH_INTERVAL_S=5`.
  - Telemetry and environment settings: `DEPLOYMENT_ENVIRONMENT=local`, `OPENOBSERVE_USER=admin@example.com`, `OPENOBSERVE_PASSWORD=change-me`, `RECEIVER_SECRET=`, `RECEIVER_FAIL_FIRST=0`.
- [X] T006 Create `compose.yaml` at the repository root, following research R14 and R16.
  - **Services**:
    - `postgres` (`postgres:16`, with a healthcheck),
    - `redis` (`redis:7`, with a healthcheck),
    - `mock_pms` (build `./mock_pms`, port `4001:4001`, `env_file: .env`, `depends_on` postgres and redis being healthy, mounts the `receiver_logs` volume at `/receiver_logs`),
    - `mock_pms_worker` (same image, `command: bin/delivery_worker`),
    - `otel-collector` (`otel/opentelemetry-collector-contrib`, which mounts `./infra/otel/collector.yaml` and mounts `/var/lib/docker/containers` read-only),
    - `openobserve` (port `5080:5080`, with `ZO_ROOT_USER_EMAIL` and `ZO_ROOT_USER_PASSWORD` taken from `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD`, and a named data volume).
  - **`tools` profile**:
    - `mock_pms_b` (a second web instance with no host port),
    - `receiver` (`command: bin/test_receiver --port 9999`, using `RECEIVER_SECRET` and `RECEIVER_FAIL_FIRST`, writing its log to the `receiver_logs` volume).
  - Pin the Collector and OpenObserve images to exact version tags that are at least two weeks old. Never use `latest`.
  - Add a header comment: "Scoped to feature 001; extended by feature 007".
- [X] T007 [P] Create `.github/workflows/ci.yml` with job `test`, which runs on `pull_request` and on `push` to `main`.
  - Service containers: `postgres:16` (health-checked) and `redis:7`, with ports mapped `5432:5432` and `6379:6379`. Inside an Actions job they are reached on `localhost`, not by service name.
  - Job-level `env:` block: `RACK_ENV=test`, `DATABASE_URL=postgres://postgres:postgres@localhost:5432/mock_pms`, `TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/mock_pms_test`, `REDIS_URL=redis://localhost:6379/0`, `ADMIN_TOKEN=ci-admin-token`. These override the `.env.example` hosts `postgres` and `redis`, which only resolve inside Compose.
  - Use `ruby/setup-ruby` with `ruby-version: '3.3'`, `bundler-cache: true`, and `working-directory: mock_pms`.
  - Steps: `bin/setup --test-db-only`, then `bundle exec rubocop`, then `bundle exec rspec`.
  - The `telemetry-smoke` job is added later, in T098.
- [X] T008 [P] Create `mock_pms/.rubocop.yml`, targeting Ruby 3.3 with `NewCops: enable`.
  - Add a custom cop or `Style` rule config, `mock_pms/.rubocop/no_direct_logger.rb`. It flags `Logger.new` and `.info/.warn/.error/.debug` calls on any receiver named `logger` outside `lib/mock_pms/logging.rb` (R12).
- [X] T009 [P] Create `mock_pms/spec/spec_helper.rb` and `mock_pms/spec/support/{db.rb,redis.rb,clock.rb}`.
  - `db.rb` connects to `TEST_DATABASE_URL`, migrates on boot, and wraps each example in `DB.transaction(rollback: :always, auto_savepoint: true)`.
  - **`:committed` examples**: these skip the rollback wrapper. Instead they run `TRUNCATE … RESTART IDENTITY CASCADE` on every table before and after the example, then re-insert the seed rows of `chaos_settings` and `chaos_counters`. Use the tag for any example where another connection, thread, or forked process has to see the rows: concurrent workers, the end-to-end receiver, and the thread or fork tests.
  - **`:slow` examples**: these are timing tests. They still run in CI.
  - `redis.rb` sets `MockPms::Redis.prefix = "mock_pms:test:#{Process.pid}:"` and deletes the keys under that prefix after each example.
  - `clock.rb` provides `freeze_time(t)` and `advance(seconds)` helpers on top of `MockPms::Clock`.
- [X] T010 [P] Create `docs/ai-build-log.md` with a header and an entry template. The template has the fields date, session type, what was done, what was blocked, decisions made, and next task, as required by the constitution's Development Workflow section.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core services that every story depends on: configuration, Postgres and Redis,
IDs and clock, logging, metrics, health, admin authentication and idempotency, the error
envelope, the app skeleton, and telemetry wiring.

**⚠️ CRITICAL**: no user-story work can start until this phase is complete.

### Tests for the foundation (write first; they must fail)

- [X] T011 [P] Write `mock_pms/spec/unit/logging_spec.rb`. These tests drive T017.
  - Using a `StringIO` sink, each log line is a single JSON object with these keys: `timestamp` (RFC 3339 UTC), `severity_text`, `body`, `service.name`, `service.version`, `deployment.environment`, `service.instance.id`, `code.function.name`, `code.file.path`, `code.line.number`, and `correlation_id`.
  - `code.function.name` is `"Dummy#work"` when logging from an instance method, `"Dummy.build"` from a class method, and `"Dummy#work"` from a block inside `#work`.
  - The redaction filter replaces values with `"[REDACTED]"` for keys matching `/token|secret|password|authorization/i` and for the keys `name`, `first_name`, `last_name`, `email`, `phone`, and `amount_cents`, including inside nested hashes.
  - Redaction happens before the line is written.
- [X] T012 [P] Write `mock_pms/spec/unit/metrics/buffer_spec.rb` and `mock_pms/spec/unit/metrics/flusher_spec.rb`. These tests drive T022 and T023.
  - The buffer records counter increments and histogram observations. Use buckets with `le` bounds `[0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10]`, plus `_sum` and `_count`.
  - `swap!` returns the deltas and leaves the buffer empty.
  - Once the cap of 10 000 fields is reached, new label sets are dropped and counted in `mock_pms_metrics_dropped_total`.
  - Against a real Redis, 4 threads each record 1 000 increments and flush concurrently. The Redis hash value then equals exactly 4 000.
  - When Redis raises during a flush, the deltas are merged back and sent on the next successful flush.
  - A flush sends a single `MULTI` using `HINCRBY` for counters and buckets and `HINCRBYFLOAT` for sums. Assert this through a Redis client spy.
- [X] T013 [P] Write `mock_pms/spec/requests/ops_spec.rb`. These tests drive T024 and T025.
  - `GET /healthz` returns `200` with `{"status":"ok","db":"ok","redis":"ok","worker_heartbeat_age_s":<n>}` when a `worker_heartbeats` row is less than 30 s old.
  - It returns `503` with `"redis":"down"` when Redis is unreachable. Stub the connection to raise.
  - It returns `503` when the heartbeat is missing or older than 30 s.
  - `GET /metrics` returns `text/plain; version=0.0.4` and contains `mock_pms_http_requests_total{route="/healthz",method="GET",status="200"}` after the flushed requests.
  - `GET /metrics` contains `target_info{service_name="mock_pms-web",service_version="<SERVICE_VERSION>",deployment_environment="<DEPLOYMENT_ENVIRONMENT>"} 1`. Principle VI requires `service.version` on all telemetry.
  - An unknown route returns the error envelope `{"error":{"code":"not_found","message":...}}` with status 404.
  - A request that sends `X-Request-Id: abc` gets `X-Correlation-Id: abc` back.
- [X] T014 [P] Write `mock_pms/spec/unit/admin/idempotency_spec.rb` and `mock_pms/spec/requests/admin_auth_spec.rb`. These tests drive T026 and T027.
  - `/admin/*` without `Authorization: Bearer <ADMIN_TOKEN>` returns `401` with the error envelope. With the wrong token it also returns `401`, using a constant-time comparison.
  - A POST with an `Idempotency-Key`, repeated with the same method, path, and body, returns the stored status and body and does not run the handler again. Use a counter to check this.
  - The same key with a different body returns `422` with `code: "idempotency_key_mismatch"`.
  - **In-flight duplicate**: hold the first request inside its handler (blocked on a latch) and send a second request with the same key. The second request gets `409 {"error":{"code":"idempotency_in_progress"}}`. Release the latch: the first request completes, and a third request with the same key returns the stored response. Tag this example `:committed`.
  - Requests without a key always run the handler.

### Implementation for the foundation

- [X] T015 [P] Create `mock_pms/config/settings.rb`, which defines `MockPms::Settings`. It reads ENV into typed, frozen values, with every default from T005.
  - `seed_anchor_date` defaults to `Date.today` (UTC) when it is empty.
  - `service_instance_id` is `ENV["HOSTNAME"]` or `Socket.gethostname`.
  - Startup fails with a clear message if `ADMIN_TOKEN` is missing.
- [X] T016 [P] Create `mock_pms/lib/mock_pms/clock.rb`, which defines `MockPms::Clock` with `now` (UTC `Time`), `today`, and a `with(fixed_or_proc)` override for tests. Also create `mock_pms/lib/mock_pms/ids.rb`, which defines `MockPms::Ids`.
  - `generate(prefix, rng: nil)` returns `"#{prefix}_"` followed by 20 characters of Crockford base32.
  - When `rng` is given, it draws from that `Random`. That is how seeded rows get reproducible IDs (R5, R9).
  - Otherwise it uses `SecureRandom`.
- [X] T017 Create `mock_pms/lib/mock_pms/logging.rb`, making T011 pass.
  - It defines a JSON formatter that uses the OTel field names listed in T011.
  - It defines `MockPms::Logging::Loggable`, which provides `log.debug`, `log.info`, `log.warn`, and `log.error`. The method name is taken from `caller_locations(1,1).first.base_label`. The class is the receiver's class, joined with `#`, or the receiver itself when it is a `Module`, joined with `.`.
  - `MockPms::Logging.service_name=` is set to `mock_pms-web`, `mock_pms-worker`, or `mock_pms-tool`.
  - The correlation ID is stored per thread, in `Thread.current[:correlation_id]`.
  - The redaction filter is applied before the line is written, as research R12 requires.
- [X] T018 Create `mock_pms/lib/mock_pms/db.rb`. It defines `MockPms::DB`, which connects with Sequel to `DATABASE_URL` (or `TEST_DATABASE_URL` when `RACK_ENV=test`).
  - It loads the `pg_json` and `pg_array` extensions.
  - It sets `Sequel.default_timezone = :utc`.
  - It adds a `MockPms::DB.migrate!` helper that runs `Sequel::Migrator` on `mock_pms/db/migrations`.
- [X] T019 [P] Create `mock_pms/lib/mock_pms/redis.rb`, which defines `MockPms::Redis`.
  - It holds a connection to `REDIS_URL`, with a key `prefix` (`mock_pms:` by default) and `key(*parts)`.
  - `load_script(name, path)` caches the script's SHA. `evalsha(name, keys:, argv:)` loads the script again if Redis replies `NOSCRIPT`.
  - `ping?` returns true or false.
- [X] T020 Create migration `mock_pms/db/migrations/001_harness.rb` for the `worker_heartbeats` and `admin_idempotency_keys` tables.
  - `worker_heartbeats`: `worker_id text PK`; `beat_at timestamptz` "updated every 5 s".
  - `admin_idempotency_keys`: `key text PK`; `request_digest text` "SHA-256 of the method, path, and body"; `response_status smallint NULL` and `response_body jsonb NULL`, both "null while in flight"; `created_at timestamptz` "rows older than 24 h may be deleted". This table is kept across `/admin/reset`.
- [X] T021 [P] Create `mock_pms/lib/mock_pms/middleware/correlation_id.rb`, making the correlation part of T013 pass.
  - It takes the ID from `X-Request-Id` or `X-Correlation-Id`, or generates one with `SecureRandom.uuid`.
  - It sets `Thread.current[:correlation_id]` and echoes the ID back as `X-Correlation-Id`.
  - It writes one access-log line per request through the mixin. `code.function.name` is the Grape endpoint (for example `MockPms::API::V1#GET /v1/payments`), and the line includes `http.request.method`, `url.path` (as the route template), `http.response.status_code`, and `duration_ms`.
  - Some responses come from middleware before Grape routes the request: 429, the 503 `rate_limiter_unavailable`, and chaos 500s. For these, `url.path` uses the same fallback route label as T023. `code.function.name` names the middleware that answered, for example `MockPms::Middleware::RateLimiter#call` or `MockPms::Middleware::ChaosErrors#call`.
- [X] T022 Create `mock_pms/lib/mock_pms/metrics/buffer.rb`, making the buffer part of T012 pass.
  - It is a delta buffer for counters and histograms, guarded by a `Mutex`.
  - Label sets are canonicalized as `k=v|k=v`, in sorted key order.
  - `swap!` runs in O(1). The buffer has the 10 000-field cap and its dropped counter.
- [X] T023 Create `mock_pms/lib/mock_pms/metrics/flusher.rb`, making the flusher part of T012 pass.
  - A background thread runs every `METRICS_FLUSH_INTERVAL_S`. Each run calls `swap!`, then sends one `MULTI` of `HINCRBY`/`HINCRBYFLOAT` to the hashes `MockPms::Redis.key("metrics", family)`.
  - On failure it merges the deltas back and logs a warning.
  - `final_flush!` does a synchronous flush at shutdown.
  - It uses no distributed lock (Constitution X; R12).
  - Then add Rack middleware `mock_pms/lib/mock_pms/middleware/request_metrics.rb`. It records `mock_pms_http_requests_total{route,method,status}` and `mock_pms_http_request_duration_seconds{route,method}`. `route` is the Grape route template, never the raw path.
    - **Fallback**: middleware can answer before Grape routes the request (429, 503, chaos 500). Then `env["grape.routing_args"]` has no template, and `route` comes from the static prefix map `{'/v1/' => '/v1/{resource}', '/oauth/' => '/oauth/{endpoint}', '/admin/' => '/admin/{endpoint}'}`. Any other path gets `unmatched`.
- [X] T024 Create `mock_pms/lib/mock_pms/metrics/exposition.rb`. It renders Prometheus text format 0.0.4 from the Redis metric hashes, with `# HELP` and `# TYPE` lines and cumulative histogram buckets. It also accepts a list of extra collectors (lambdas that return samples), so that later database-backed delivery metrics can plug in (T074). It always emits `target_info{service_name="mock_pms-web",service_version=Settings.service_version,deployment_environment=Settings.deployment_environment} 1`. The Collector turns that line into resource attributes (Constitution VI; R16).
- [X] T025 Create `mock_pms/lib/mock_pms/api/ops.rb`, a Grape API that serves `/healthz` (DB `SELECT 1`, `MockPms::Redis.ping?`, the newest `worker_heartbeats.beat_at`) and `/metrics`, making T013's `/healthz` and `/metrics` cases pass. Also create `mock_pms/lib/mock_pms/api/errors.rb`. It defines a Grape error formatter that produces `{"error":{"code","message"}}`, with handlers for 404, 422 (validation), and 500.
- [X] T026 Create `mock_pms/lib/mock_pms/api/admin_base.rb`. It defines admin authentication: a `before` hook comparing `Authorization: Bearer` against `Settings.admin_token` with `Rack::Utils.secure_compare`, and returning 401 with the envelope on a mismatch. Also create `mock_pms/lib/mock_pms/admin/idempotency.rb`, a helper `with_idempotency(env) { ... }` that uses `admin_idempotency_keys` (R11).
  - `request_digest` is the SHA-256 of `"#{method}\n#{path}\n#{body}"`.
  - The key row is inserted with `INSERT ... ON CONFLICT DO NOTHING`, so it is claimed atomically. `response_status` and `response_body` stay null until the handler finishes.
  - On a conflict:
    - a row whose `request_digest` differs returns `422 idempotency_key_mismatch`;
    - a row with null `response_status` (the first request is still in flight) returns `409 idempotency_in_progress`;
    - otherwise the stored response is returned.
  - If the handler raises, the key row is deleted, so the client can retry.
  - **Secrets**: endpoints whose response contains a secret MUST NOT use `with_idempotency`. Today that is only `POST /admin/clients`, which returns the one-time `client_secret` (R4).
  - These two files make T014 pass.
- [X] T027 Create `mock_pms/lib/mock_pms/app.rb`, defining `MockPms::App`. This is the Rack builder.
  - Middleware order: `CorrelationId` → `RequestMetrics` → (rate limiter slot, filled in T079) → (chaos errors slot, filled in T089) → `Grape` cascade.
  - It mounts `API::Ops` and `API::AdminBase`.
  - It starts `Metrics::Flusher` (except under `RACK_ENV=test`, where specs flush explicitly).
  - Also create `mock_pms/config.ru`, which runs `MockPms::App`, and `mock_pms/lib/mock_pms.rb`, which loads `Settings`, `DB`, `Redis`, and `Logging` and sets `Logging.service_name = "mock_pms-web"`.
- [X] T028 Create `mock_pms/bin/setup` (executable Ruby).
  - It creates the `mock_pms` and `mock_pms_test` databases if they are missing and runs migrations.
  - It seeds unless `--test-db-only` is passed. Until T044 exists, seeding is a no-op.
  - It uses `Logging.service_name = "mock_pms-tool"`.
- [X] T029 [P] Create `infra/otel/collector.yaml`, implementing research R16.
  - **Receivers**:
    - `filelog`: include `/var/lib/docker/containers/*/*-json.log`. A `container` operator parses the files, and a `router` keeps only lines whose container name matches `mock_pms*`. A `json_parser` reads the body. Resource attributes are promoted from `service.name`, `service.version`, `deployment.environment`, and `service.instance.id`, and severity is mapped from `severity_text`.
    - `prometheus`: one scrape job, `mock_pms`, that targets `mock_pms:4001` every `15s`. Keep the receiver's default `target_info` handling turned on, so `service.name=mock_pms-web`, `service.version`, and `deployment.environment` become resource attributes on every series. Don't set a static `service.name`. Use the same name as the web service's logs (`mock_pms-web`).
  - **Processors**: `memory_limiter`, `batch`, and an `attributes/redact` processor that deletes keys matching the T017 redaction list.
  - **Exporters**: `otlphttp/openobserve`, with `endpoint: http://openobserve:5080/api/default`, Basic auth from `${env:OPENOBSERVE_USER}`/`${env:OPENOBSERVE_PASSWORD}`, `sending_queue` (in memory, `queue_size: 1000`), and `retry_on_failure` turned on. Put a comment above the exporter stating the R16 loss bound.
  - **Self-monitoring**: set `service.telemetry.metrics` to expose the Collector's own metrics on `0.0.0.0:8888`. Add a second `prometheus` scrape job, `otel-collector`, targeting `localhost:8888`, so the drop counters (`otelcol_exporter_send_failed_*`, `otelcol_exporter_queue_size`, `otelcol_processor_refused_*`) also reach OpenObserve.
  - **Pipelines**: `logs` and `metrics`.
- [X] T030 [P] Write `docs/adr/0004-otlp-collector-bridge.md` (ADR-0004), following research R16. It needs these sections:
  - **Context**: Constitution VI requires OTLP delivery, and the Ruby OTel metrics and logs SDKs are 0.x.
  - **Decision**: a Collector bridge to OpenObserve.
  - **Alternatives**: native SDKs; the fluentd logging driver; vendor ingestion APIs.
  - **Consequences**: the services have no OTel gems; the Collector's own metrics count drops; when to revisit (once the Ruby metrics and logs SDKs reach 1.0).

**Checkpoint**: run `docker compose up -d postgres redis mock_pms` and `bin/setup`. Then
`/healthz` returns 200 (while a worker heartbeat row exists), `/metrics` renders, and
`bundle exec rspec` passes.

---

## Phase 3: User Story 1 - Connect and read a realistic portfolio (Priority: P1) 🎯 MVP

**Goal**: An integration client can be registered, can send a seeded operator through the
OAuth authorization-code flow, and can page through that operator's properties, tenants,
leases, charges, and payments. The underlying 12-month history is deterministic.

**Independent Test**: Start a fresh harness, register a client, and approve it as one seeded
operator. Exchange the code, then page through every `/v1` resource. Counts and data mix match
`bin/seed_report`. No other operator's records ever appear. The token edge cases behave as in
spec US1 scenarios 1–5 (quickstart §3–§4).

### Tests for User Story 1 (write first; they must fail) ⚠️

- [ ] T031 [P] [US1] Write `mock_pms/spec/unit/oauth/lifecycle_spec.rb`, testing `MockPms::OAuth::Service` against the test database with a frozen clock.
  - An approval issues a code. The code `expires_at` is "issue time + 60 s".
  - A code can be exchanged only once: the second exchange gets `invalid_grant`.
  - An expired code gets `invalid_grant`. So does a `redirect_uri` mismatch.
  - With PKCE S256, a wrong `code_verifier` gets `invalid_grant`.
  - The access token `expires_at` is "issue time + `ACCESS_TOKEN_TTL` (300 s)". The refresh token's is "issue time + 30 days".
  - A refresh returns a new pair, and the old refresh token then gets `invalid_grant`.
  - Validation order: an unknown digest is `:invalid`, a revoked grant is `:invalid`, a token past `expires_at` is `:expired`, and anything else is `:valid`.
  - Revoking the grant invalidates both its access and refresh tokens.
  - When the same operator approves the same client again, the existing active grant is reused.
- [ ] T032 [P] [US1] Write `mock_pms/spec/unit/pagination_spec.rb`, testing `MockPms::Pagination`.
  - Cursors round-trip as URL-safe base64 of the last `seq`.
  - `limit` defaults to 50. A `limit` above 200, below 1, or that isn't an integer is **rejected** with 422 `{"error":{"code":"invalid_parameter",...}}`; it is never clamped (contract `minimum: 1`, `maximum: 200`). A malformed `cursor` is also rejected with 422.
  - **Stability**: with 120 rows and pages of 50, inserting 10 rows while paging means no original row is skipped or repeated, and the new rows show up after the original ones.
  - An `updated_since` filter narrows the results without changing the `seq` order.
- [ ] T033 [P] [US1] Write `mock_pms/spec/unit/seed/determinism_spec.rb`, testing `MockPms::Seed::Generator` and `MockPms::Seed::Digest`.
  - Two runs with `seed: 42, anchor_date: 2026-10-20` produce identical `data_digest`s, with a `TRUNCATE ... RESTART IDENTITY CASCADE` between them.
  - `seed: 7` produces a different digest.
  - The digest excludes `seq`, `password_digest`, and all OAuth, delivery, and harness tables.
  - No seeded `created_at` is later than the anchor date's end of day.
  - **Timing** (`:slow`): seeding with `seed: 42` finishes in under 60 s (SC-002).
  - **Profile**:
    - exactly 3 operators, with about 25, 15, and 10 properties (50 in total), and 60 leases;
    - at least 3 leases with status `ended_early`;
    - each payment-behavior category present (on-time, late at 3, 7, 12, and 20+ days, a partial later completed, a partial never completed, an NSF reversal, unpaid);
    - at least one NSF reversal of a **partial** payment, whose reversal `amount_cents` equals that partial payment's full amount (spec edge case "Reversal of a partial payment");
    - charges span the 12 months ending with the anchor month;
    - no rent charge `period` falls after a lease's `actual_end_date`;
    - every reversal's `amount_cents` equals its payment's amount.
- [ ] T034 [P] [US1] Write `mock_pms/spec/requests/oauth_spec.rb`, which drives the HTTP endpoints from contracts/openapi.yaml.
  - **Authorize page**: `GET /oauth/authorize` with a registered client renders HTML. With an unknown `client_id` or an unregistered `redirect_uri`, it returns 400 and does not redirect.
  - **Approval**: `POST /oauth/authorize` with valid credentials and `decision=approve` returns 302 to `redirect_uri?code=…&state=xyz`. `decision=deny` returns 302 to `?error=access_denied&state=xyz`. Wrong credentials return 200 with the form re-rendered.
  - **Token endpoint**: `POST /oauth/token` accepts both `client_secret_basic` and `client_secret_post`. The response JSON matches `TokenResponse` (`token_type: "Bearer"`, `scope: "read"`). A bad client secret returns 401 `invalid_client`.
  - The token endpoint is never rate limited and never chaos-affected. Check this again in US3 and US4.
- [ ] T035 [P] [US1] Write `mock_pms/spec/requests/v1_spec.rb`.
  - **Auth**: an expired token returns 401 with `WWW-Authenticate: Bearer error="invalid_token", error_description="token expired"`. A revoked or unknown token returns 401 with `error_description="token invalid"`.
  - **Scoping**: each of `/v1/properties`, `/v1/tenants`, `/v1/leases`, `/v1/charges`, and `/v1/payments` returns only the token operator's records, with `{data, next_cursor}`.
  - **Single records**: `GET /v1/{resource}/{id}` for another operator's ID returns 404.
  - **Filters**: `property_id`, `tenant_id`, and `status` on leases; `lease_id` with `from`/`to` (`due_date`) on charges; and `lease_id` with `from`/`to` (`received_at`) on payments.
  - **Shapes**: every record matches its openapi schema. Amounts are `{amount_cents, currency}`. Reversed payments include a `reversal` object and `applied_to`.
- [ ] T036 [P] [US1] Write `mock_pms/spec/requests/admin_clients_spec.rb`.
  - `POST /admin/clients` returns 201 with `client_id` (`client_` prefix), `client_secret`, and `signing_secret`. The `client_secret` is shown only in this response.
  - Afterwards, only `secret_digest` (the SHA-256) is stored. No row of `admin_idempotency_keys` contains the `client_secret` or `signing_secret` value.
  - `POST /admin/clients` ignores an `Idempotency-Key` header. Each request registers a new client, because the response carries a one-time secret.
  - `redirect_uris` must have at least one entry, otherwise the request returns 422.
  - `GET /admin/clients` never returns secrets.
  - `PATCH /admin/clients/{id}` updates `subscriber_url`, `redirect_uris`, and `rate_limit_per_minute`.
  - `POST /admin/grants/{id}/revoke` is idempotent: repeating it returns 200 with the original `revoked_at`.
  - `GET /admin/grants` lists `client`, `operator`, `created_at`, and `revoked_at`.

### Implementation for User Story 1

- [ ] T037 [US1] Create migration `mock_pms/db/migrations/002_business.rb`. Every table **except `payment_applications`** gets `seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`, `id text UNIQUE NOT NULL`, and `created_at`/`updated_at timestamptz NOT NULL`. `payment_applications` has only its composite primary key. Every foreign key is NOT NULL unless the data model says otherwise.
  - **`operators`**:
    - `name text NOT NULL`
    - `login text UNIQUE NOT NULL`
    - `password_digest text NOT NULL`
    - `timezone text NOT NULL DEFAULT 'America/Chicago'`
  - **`properties`**:
    - `operator_seq` FK (indexed)
    - `address_line1`, `city`, `state`, `postal_code` (all text)
    - `bedrooms smallint`, `bathrooms numeric(3,1)`
    - `status text CHECK (status IN ('occupied','vacant','make_ready'))`
  - **`tenants`**:
    - `operator_seq` FK (indexed)
    - `first_name`, `last_name`, `email`, `phone` (all text)
    - `status text CHECK (status IN ('current','former'))`
  - **`leases`**:
    - `operator_seq`, `property_seq`, `tenant_seq` FKs
    - `start_date date`
    - `scheduled_end_date date CHECK (scheduled_end_date > start_date)`
    - `actual_end_date date NULL CHECK (actual_end_date <= scheduled_end_date)`
    - `monthly_rent_cents integer CHECK (> 0)`
    - `currency char(3) NOT NULL DEFAULT 'USD'`. It applies to `monthly_rent_cents` and `late_fee_cents`, and the presenter emits it in `monthly_rent` and `late_fee` (FR-010)
    - `due_day smallint CHECK (due_day BETWEEN 1 AND 28)`
    - `grace_days smallint DEFAULT 3`
    - `late_fee_cents integer DEFAULT 7500`
    - `status text CHECK (status IN ('pending','active','ended','ended_early'))`
    - A partial unique index on `(property_seq) WHERE status = 'active'` enforces "at most one lease per property may be `active` at a time".
  - **`charges`**:
    - `operator_seq`, `lease_seq` FKs
    - `kind text CHECK (kind IN ('rent','late_fee'))`
    - `period date` ("first day of the month the charge covers")
    - `due_date date`
    - `amount_cents integer CHECK (> 0)`
    - `currency char(3) NOT NULL DEFAULT 'USD'`
    - `UNIQUE (lease_seq, kind, period)`
  - **`payments`**:
    - `operator_seq`, `lease_seq` FKs
    - `amount_cents integer CHECK (> 0)`
    - `currency char(3) DEFAULT 'USD'`
    - `received_at timestamptz`
    - `method text CHECK (method IN ('ach','card','check','money_order'))`
    - `status text CHECK (status IN ('settled','reversed'))`
  - **`payment_applications`**:
    - `payment_seq`, `charge_seq` FKs
    - `amount_cents integer CHECK (> 0)`
    - `PRIMARY KEY (payment_seq, charge_seq)`
  - **`reversals`**:
    - `seq`, `id` (`rev_` prefix)
    - `payment_seq` FK, **UNIQUE**
    - `reason text CHECK (reason IN ('nsf','account_closed','stop_payment'))`
    - `reversed_at timestamptz`
    - `amount_cents integer`
- [ ] T038 [US1] Create migration `mock_pms/db/migrations/003_oauth.rb`.
  - **`clients`**:
    - `seq`, `id` (`client_` prefix)
    - `name text`
    - `secret_digest text` ("SHA-256 of the client secret")
    - `redirect_uris text[] NOT NULL CHECK (cardinality(redirect_uris) >= 1)`
    - `subscriber_url text NULL`
    - `signing_secret text NOT NULL` ("stored as given (R4)")
    - `rate_limit_per_minute integer NULL`
    - timestamps
  - **`grants`**:
    - `seq`, `id` (`grant_` prefix)
    - `client_seq`, `operator_seq` FKs
    - `scope text NOT NULL DEFAULT 'read'`
    - `created_at`
    - `revoked_at timestamptz NULL`
    - A partial unique index on `(client_seq, operator_seq) WHERE revoked_at IS NULL`.
  - **`authorization_codes`**:
    - `code_digest text PK`
    - `grant_seq` FK
    - `redirect_uri text NOT NULL`
    - `code_challenge text NULL`, `code_challenge_method text NULL`
    - `expires_at timestamptz NOT NULL`
    - `used_at timestamptz NULL`
  - **`access_tokens`**:
    - `token_digest text PK`
    - `grant_seq` FK
    - `expires_at timestamptz NOT NULL`
    - `created_at`
  - **`refresh_tokens`**: the same columns as `access_tokens`, plus `used_at timestamptz NULL`.
- [ ] T039 [P] [US1] Create Sequel models in `mock_pms/lib/mock_pms/models/` for the business tables: `operator.rb`, `property.rb`, `tenant.rb`, `lease.rb`, `charge.rb`, `payment.rb`, `payment_application.rb`, and `reversal.rb`.
  - Set up the associations from the data-model Relationships section.
  - Add validations that mirror the database constraints.
  - Add model-level invariants:
    - a lease's `operator_seq` "must equal the property's operator";
    - a payment's applications must not add up to more than the payment, and a charge's must not add up to more than the charge;
    - a reversal's `reversed_at` "must be later than the payment's `received_at`", and its `amount_cents` "must equal the payment's full amount";
    - charges with a `period` after the lease's `actual_end_date` are rejected.
- [ ] T040 [P] [US1] Create Sequel models `mock_pms/lib/mock_pms/models/{client,grant,authorization_code,access_token,refresh_token}.rb`. Add `Grant#active?` and the dataset method `Grant.active`.
- [ ] T041 [US1] Implement `mock_pms/lib/mock_pms/oauth/service.rb`, `MockPms::OAuth::Service`, making T031 pass.
  - **Issuing**: `approve!(client:, operator:, redirect_uri:, code_challenge:, method:)` reuses or creates the active grant and issues a code (32 or more random bytes, stored as a SHA-256 digest).
  - **Code exchange**: `exchange_code!(client:, code:, redirect_uri:, code_verifier:)` claims the code with a single-use update, `UPDATE authorization_codes SET used_at = now() WHERE code_digest = ? AND used_at IS NULL AND expires_at > now()`. Zero rows changed means `invalid_grant`. The token pair is issued in the same transaction.
  - **Refresh**: `refresh!(client:, refresh_token:)` rotates the pair with the same single-use update on `refresh_tokens`.
  - **Validation**: `validate_access_token(raw)` returns `[:valid, grant] | [:expired, nil] | [:invalid, nil]`, checking in the order from data-model.md.
  - **Revocation**: `revoke!(grant)`.
  - Use `MockPms::Clock` for every time check.
- [ ] T042 [US1] Implement `mock_pms/lib/mock_pms/api/oauth.rb` and `mock_pms/lib/mock_pms/views/authorize.html.erb`, making T034 pass.
  - **`GET /oauth/authorize`**: validates the client and an exact `redirect_uri` match, then renders the minimal sign-in-and-approve form with stdlib ERB, escaping all values.
  - **`POST /oauth/authorize`**: checks the operator's password with bcrypt, then redirects with a code or `error=access_denied`.
  - **`POST /oauth/token`**: handles both client-auth methods. Errors follow RFC 6749, as `{error, error_description}`, using the statuses in the contract.
  - Mount the API in `MockPms::App` (T027).
- [ ] T043 [P] [US1] Implement `mock_pms/lib/mock_pms/pagination.rb`, `MockPms::Pagination.paginate(dataset, limit:, cursor:)`, making T032 pass. It orders by `seq ASC`, takes the keyset `WHERE seq > decoded_cursor`, fetches `limit + 1` rows to find out whether a next page exists, and returns `[rows, next_cursor_or_nil]`.
- [ ] T044 [US1] Implement `mock_pms/lib/mock_pms/seed/wordlists.rb` and `mock_pms/lib/mock_pms/seed/generator.rb`, `MockPms::Seed::Generator.run(seed:, anchor_date:)`, following research R5. Part of T033 passes after this task.
  - Use one `Random.new(seed)` for everything.
  - Public IDs come from `Ids.generate(prefix, rng:)`.
  - Every timestamp comes from the simulated history anchored on `anchor_date`. The wall clock is never used.
  - Operators have fixed logins and passwords `"<login>-pass"`, hashed with bcrypt.
  - **Operators and properties**: 3 operators, with 25, 15, and 10 properties.
  - **Leases**: 60 leases. Some properties have two tenants in the 12-month window.
  - **Payment behavior per month**: about 70% on time, about 15% late (3, 7, 12, or 20+ days, with a `late_fee` charge), about 8% partial (half later completed, half never completed), about 3% NSF reversal (each followed by a repayment or left unpaid), and the rest unpaid. At least one NSF reversal MUST target a partial payment, and it reverses that payment's full amount.
  - **Move-outs**: 4 tenants move out mid-lease. Their lease is set to `ended_early` with `actual_end_date`, and the tenant to `former`. No charges are generated after the move-out.
  - **`payment_applications`**: written in the way the PMS reports applications.
- [ ] T045 [US1] Implement `mock_pms/lib/mock_pms/seed/digest.rb`, `MockPms::Seed::Digest.compute`, and write `seed_runs` in migration `mock_pms/db/migrations/004_seed_runs.rb`. The `seed_runs` columns are `seq`, `seed bigint`, `anchor_date date`, `data_digest text`, and `ran_at timestamptz`. T033 passes fully after this task.
  - The digest is a canonical JSON dump of the `/v1`-visible fields of operators (without `password_digest`), properties, tenants, leases, charges, and payments (with applications and reversals).
  - Within each table, rows are ordered by `id`. Keys are sorted, and timestamps are UTC ISO 8601 at second precision.
  - The digest is the SHA-256 of that dump.
  - Seeded events are added to the digest in T068.
- [ ] T046 [US1] Implement `mock_pms/lib/mock_pms/seed/reset.rb`, `MockPms::Seed::Reset.run!(seed:, anchor_date:)`. It runs `TRUNCATE ... RESTART IDENTITY CASCADE` on every business, OAuth, event, and delivery table, and on `worker_heartbeats`. It resets both `chaos_counters` rows to 0. It **keeps `admin_idempotency_keys` and `seed_runs`**, which are audit and harness state rather than seed state, so an idempotent `/admin/reset` can still find its own key afterwards. It then regenerates the data and records a `seed_runs` row. It returns `{seed, anchor_date, data_digest}`.
  - It does not clear Redis metrics.
  - Then wire `bin/setup` to call it (T028).
  - Create `mock_pms/bin/reseed`, which takes `--seed N --anchor YYYY-MM-DD` and prints the digest.
- [ ] T047 [P] [US1] Create `mock_pms/bin/seed_report`. It prints counts per operator (properties, leases, tenants), the payment-behavior mix per category, the `ended_early` leases, and the operator logins and passwords for the approval page. It uses `Logging.service_name = "mock_pms-tool"`, and prints the report itself on stdout, separate from the log lines.
- [ ] T048 [P] [US1] Create presenters `mock_pms/lib/mock_pms/presenters/{property,tenant,lease,charge,payment}.rb`. Each one turns a model into the exact `/v1` JSON shape in contracts/openapi.yaml:
  - public `id`s only, never `seq`;
  - `property_id`, `tenant_id`, and `lease_id` as public IDs;
  - money as `{amount_cents, currency}`;
  - for payments, `applied_to: [{charge_id, amount_cents}]` and `reversal`, which is either null or `{id, reason, reversed_at, amount_cents}`.

  The webhook envelope in US2 reuses these presenters.
- [ ] T049 [US1] Implement `mock_pms/lib/mock_pms/api/v1.rb`, making T035 pass.
  - A `before` hook reads `Authorization: Bearer` and calls `OAuth::Service.validate_access_token`. An expired or invalid token gets 401 with the matching `WWW-Authenticate` value.
  - The grant's `operator_seq` is stored in `env["mock_pms.operator_seq"]` and the client's `seq` in `env["mock_pms.client_seq"]`. US3 reads the latter.
  - It serves the list endpoints for the five resources, with the filters from T035, `updated_since`, and `Pagination`. Every dataset is scoped `WHERE operator_seq = ?`.
  - It serves `GET /v1/{resource}/{id}`, which returns 404 when the record is not in scope.
  - Mount the API in `MockPms::App`.
- [ ] T050 [US1] Implement `mock_pms/lib/mock_pms/api/admin.rb` client and grant endpoints, making T036 pass. Mount them in `AdminBase`. Use `with_idempotency` on `POST /admin/grants/{grant_id}/revoke`. `POST /admin/clients` does **not** use it, because its response contains the one-time `client_secret` (R4; see T026).
  - **`POST /admin/clients`**: generates `client_secret` (stored only as its SHA-256), and `signing_secret` (prefix `whsec_`, stored as given).
  - **Other endpoints**: `GET /admin/clients`, `PATCH /admin/clients/{client_id}`, `GET /admin/grants`, and `POST /admin/grants/{grant_id}/revoke` (calls `OAuth::Service.revoke!`; idempotent).
- [ ] T051 [P] [US1] Write `docs/adr/0002-hand-written-oauth-server.md` (ADR-0002), from research R3.
  - **Context**: the narrow flow needed, and that Doorkeeper requires Rails.
  - **Decision**: opaque random tokens, stored as SHA-256 digests, with single-use codes and rotating refresh tokens.
  - **Alternatives**: Doorkeeper; `rack-oauth2`; JWT (rejected because revocation would not be immediate).
  - **Consequences**: no reuse-detection revocation; supporting a scope only takes changing one constant.

**Checkpoint**: quickstart §3 (seed determinism) and §4 (connect and read) pass by hand. US1
is a usable MVP: feature 002's OAuth and reconciliation work can start against it.

---

## Phase 4: User Story 2 - Receive signed webhooks for business events (Priority: P1)

**Goal**: business changes record immutable events. Each event is delivered as a signed POST
to every subscribed client with an active grant. Failed deliveries are retried with backoff,
and every attempt is logged.

**Independent Test**: start the `receiver` tool service with the client's signing secret.
Trigger `tenant_move_out` and `nsf_wave`. Check that `lease.updated`, `tenant.moved_out`, and
`payment.reversed` arrive within 5 s with valid signatures. With `RECEIVER_FAIL_FIRST=3`, the
4th attempt succeeds with the same `PMS-Event-Id`, and `/admin/deliveries` shows all four
attempts (quickstart §5).

### Tests for User Story 2 (write first; they must fail) ⚠️

- [ ] T052 [P] [US2] Create the fixture `mock_pms/spec/fixtures/signature_vector.json`, computed **independently of the implementation**. Run `printf '%s' '1792540800.{"id":"evt_TEST","type":"payment.created"}' | openssl dgst -sha256 -hmac 'whsec_test_0123456789abcdef'` and store `{secret, t, body, v1}`, with `v1` the resulting hex digest. The vector is in contracts/webhooks.md. Feature 002 reuses this file.
- [ ] T053 [P] [US2] Write `mock_pms/spec/unit/delivery/signer_spec.rb`.
  - `Signer.header(secret:, t:, body:)` returns exactly `"t=1792540800,v1=<fixture v1>"`.
  - `Signer.verify(header:, secret:, body:)` returns true for the fixture and false when one byte of the body is changed.
  - The header is computed over raw bytes, including bodies that are not valid UTF-8.
- [ ] T054 [P] [US2] Write `mock_pms/spec/unit/delivery/retry_schedule_spec.rb`.
  - With `base: 2` and jitter fixed at 0, the delay after attempt *n* is `2 * 2**(n-1)`, so attempts 1–7 give `[2,4,8,16,32,64,128]`.
  - With jitter turned on, every delay is within ±10%.
  - After `MAX_ATTEMPTS` (8), `next_delay` returns nil, which marks the delivery `exhausted`.
- [ ] T055 [P] [US2] Write `mock_pms/spec/unit/events/recorder_spec.rb`.
  - `Recorder.record!(type:, operator:, payload:, occurred_at:, source:)` inserts one immutable `events` row (with an `evt_` id) in the caller's transaction.
  - It inserts one `deliveries` row per client that has an active grant for that operator and a non-null `subscriber_url`. The delivery `scheduled_at` is now, `status` is `pending`, and `chaos` is `{}`.
  - Clients with no subscriber, a revoked grant, or a grant for another operator get no row.
  - If the business change rolls back, no event or delivery remains.
  - `correlation_id` is taken from `Thread.current`.
  - Updating an event raises an error, enforced by a database trigger.
- [ ] T056 [P] [US2] Write `mock_pms/spec/unit/delivery/worker_spec.rb`, with an injected fake transport and a frozen clock.
  - The worker claims due deliveries with `FOR UPDATE SKIP LOCKED`. Two workers running concurrently, in two threads with separate DB connections, never claim the same row. Tag this example `:committed`.
  - A 2xx response inserts a `delivery_attempts` row with outcome `success` and sets the status to `succeeded`.
  - A 500 response, a timeout (more than 10 s), or a connection error inserts the matching outcome (`http_error` with `http_status`, `timeout`, or `connection_error`). The delivery is rescheduled with the retry schedule and gets `attempt_count += 1`.
  - After the 8th failure the status is `exhausted`.
  - A delivery left `in_flight` for more than 60 s goes back to `pending`.
  - Headers sent: `Content-Type: application/json; charset=utf-8`, `PMS-Event-Id`, `PMS-Event-Type`, `PMS-Delivery-Id`, `PMS-Delivery-Attempt`, `PMS-Signature` (with a fresh `t` on every attempt), `X-Correlation-Id`, and `PMS-Replay` only when the delivery is a replay.
  - The body is the envelope from contracts/webhooks.md: `id`, `type`, `occurred_at`, `operator_id`, `api_version: "2026-10-01"`, and `data.object`.
- [ ] T057 [P] [US2] Write `mock_pms/spec/unit/scenarios/{tenant_move_out,nsf_wave}_spec.rb`.
  - `TenantMoveOut.run!(operator: nil)` picks one `active` lease and sets it to `ended_early` with `actual_end_date`. The tenant becomes `former`.
  - It emits `lease.updated` and then `tenant.moved_out`, with the same `occurred_at` and `correlation_id`. The `tenant.moved_out` `data.object` is `{tenant, lease, move_out_date}`.
  - `NsfWave.run!(count: 5)` reverses `count` recent `settled` payments, writing one `reversals` row each with `reason: nsf`. It emits `payment.reversed` with `status: reversed` and a `reversal` object filled in.
  - Each scenario returns `ScenarioResult` (`scenario`, `run_id`, `events_created`, `counts`), and `run_id` equals the `correlation_id` of every event it creates.
- [ ] T058 [P] [US2] Write `mock_pms/spec/requests/admin_events_spec.rb`.
  - `GET /admin/events` (with `type`, `operator_id`, `since`, and pagination) and `GET /admin/deliveries` (with `client_id`, `event_id`, `status`, and pagination) return the contract `Delivery` shape, including `attempts`.
  - `POST /admin/scenarios/{tenant_move_out|nsf_wave}` returns 200 with a `ScenarioResult`. An unknown name returns 404.
  - Repeating a scenario POST with the same `Idempotency-Key` returns the same `run_id` and creates no new events.
- [ ] T059 [US2] Write `mock_pms/spec/integration/delivery_end_to_end_spec.rb`. Tag the whole file `:committed`, because the worker and receiver threads use their own connections.
  - Start a throwaway receiver: a Rack app on Puma, on a random port, in a thread, that records requests.
  - Register a client with that `subscriber_url`, then grant it.
  - Run `TenantMoveOut`, then run `Delivery::Worker#run_once` until no deliveries are due.
  - Check that two requests arrived, in `occurred_at` order, and that each signature verifies with the client's `signing_secret`.
  - Check that the receiver saw `X-Correlation-Id` equal to the scenario's `run_id`.
  - **Timing** (`:slow`): with chaos off and the worker polling every 1 s, each delivery reaches the receiver no more than 5 s after its event's `created_at` (SC-003).
  - Make the receiver return 500 twice. The third attempt then succeeds with the same `PMS-Event-Id`, and the delivery has 3 `delivery_attempts`.

### Implementation for User Story 2

- [ ] T060 [US2] Create migration `mock_pms/db/migrations/005_events_deliveries.rb`.
  - **`events`**:
    - `seq`, `id` (`evt_` prefix)
    - `operator_seq` FK
    - `type text CHECK (type IN ('payment.created','payment.reversed','lease.updated','tenant.moved_out'))`
    - `occurred_at timestamptz NOT NULL`
    - `payload jsonb NOT NULL`
    - `correlation_id text NOT NULL`
    - `source text NOT NULL` ("`seed`, `scenario:<name>`, or `admin`")
    - `created_at`
    - A `BEFORE UPDATE OR DELETE` trigger that raises, because "events are never updated or deleted".
  - **`deliveries`**:
    - `seq`, `id` (`dlv_` prefix)
    - `event_seq`, `client_seq` FKs
    - `scheduled_at timestamptz NOT NULL`
    - `status text CHECK (status IN ('pending','in_flight','succeeded','exhausted'))`
    - `attempt_count smallint NOT NULL DEFAULT 0`
    - `replay boolean NOT NULL DEFAULT false`
    - `chaos jsonb NOT NULL DEFAULT '{}'`
    - timestamps
    - An index on `(status, scheduled_at)`.
  - **`delivery_attempts`**:
    - `seq`
    - `delivery_seq` FK
    - `attempt_number smallint` (with `UNIQUE (delivery_seq, attempt_number)`)
    - `started_at`, `finished_at timestamptz`
    - `outcome text CHECK (outcome IN ('success','http_error','timeout','connection_error'))`
    - `http_status smallint NULL`
    - `chaos_applied jsonb`
    - `correlation_id text`
    - A trigger that blocks `UPDATE` and `DELETE`, so the table is immutable.
- [ ] T061 [P] [US2] Create Sequel models `mock_pms/lib/mock_pms/models/{event,delivery,delivery_attempt}.rb`. Add `Delivery.due(now)`, which returns `status = 'pending' AND scheduled_at <= now`, ordered by `scheduled_at, seq`.
- [ ] T062 [P] [US2] Implement `mock_pms/lib/mock_pms/delivery/signer.rb`, `MockPms::Delivery::Signer`, using `OpenSSL::HMAC.hexdigest("SHA256", secret, "#{t}.#{body}")` and a constant-time `verify`. This makes T053 pass.
- [ ] T063 [P] [US2] Implement `mock_pms/lib/mock_pms/delivery/retry_schedule.rb`, making T054 pass. It reads `RETRY_BASE_SECONDS` and `MAX_ATTEMPTS`, and takes an injectable jitter source.
- [ ] T064 [US2] Implement `mock_pms/lib/mock_pms/events/serializer.rb`, which builds the envelope from contracts/webhooks.md using the T048 presenters, with `api_version` fixed at `"2026-10-01"`. Also implement `mock_pms/lib/mock_pms/events/recorder.rb`, which records the event and fans it out to deliveries in the caller's transaction (FR-017). Leave a single `chaos_for(event, client)` hook that returns `{}` for now; US4 replaces it. This task makes T055 pass.
- [ ] T065 [P] [US2] Implement `mock_pms/lib/mock_pms/delivery/transport.rb`, a `Net::HTTP` POST wrapper with `open_timeout` and `read_timeout` of 10 s. It returns `{outcome:, http_status:}`. Tests inject a replacement.
- [ ] T066 [US2] Implement `mock_pms/lib/mock_pms/delivery/worker.rb`, making T056 pass.
  - **`run_once`**: in a transaction, claim up to 20 due deliveries with `FOR UPDATE SKIP LOCKED` and set them to `in_flight`. Then send each one, insert a `delivery_attempts` row, and either set `succeeded`, or reschedule with `RetrySchedule`, or set `exhausted`.
  - **Reaper**: `in_flight` rows with `updated_at < now - 60 s` go back to `pending`.
  - **Heartbeat**: upsert `worker_heartbeats` every 5 s.
  - **Telemetry**: record `mock_pms_delivery_send_duration_seconds{outcome}` in the metrics buffer, and log each attempt (`code.function.name` = `MockPms::Delivery::Worker#deliver`).
  - Set `Logging.service_name = "mock_pms-worker"`.
- [ ] T067 [US2] Create `mock_pms/bin/delivery_worker`. It loops `run_once` with a 1 s poll, starts its own `Metrics::Flusher`, and handles `TERM` and `INT` by finishing the current batch and calling `final_flush!`.
- [ ] T068 [US2] Extend `Seed::Generator` (T044) so it also writes the historical `events` that the seeded history would have produced, with `source: "seed"`, IDs from the seed RNG, `occurred_at` set to historical times, and **no deliveries**. Extend `Seed::Digest` (T045) to include the seeded events, ordered by `id`. Then run T033 again; it must stay green.
- [ ] T069 [US2] Implement `mock_pms/lib/mock_pms/scenarios/base.rb`. It runs a scenario inside a transaction, sets `Thread.current[:correlation_id] = run_id` (a UUID), and returns a `ScenarioResult`. Then implement `mock_pms/lib/mock_pms/scenarios/tenant_move_out.rb` and `mock_pms/lib/mock_pms/scenarios/nsf_wave.rb`. Business changes go through the models, and events through `Events::Recorder`. This task makes T057 pass.
- [ ] T070 [US2] Add to `mock_pms/lib/mock_pms/api/admin.rb`:
  - `GET /admin/events`;
  - `GET /admin/deliveries`, including each delivery's `attempts`;
  - `POST /admin/scenarios/{name}`, which dispatches through a registry of `month_end_burst`, `nsf_wave`, and `tenant_move_out`. `month_end_burst` returns 404 until T094. The endpoint is wrapped in `with_idempotency`.

  This task makes T058 pass.
- [ ] T071 [US2] Make the end-to-end spec T059 pass. Fix any integration gaps it finds in the recorder, worker, or transport, and leave the spec itself unchanged.
- [ ] T072 [P] [US2] Create `mock_pms/bin/test_receiver`. It is a small Rack app on Puma that listens on `0.0.0.0:<--port>` and accepts `POST /webhooks`.
  - It verifies `PMS-Signature` with `RECEIVER_SECRET` using `Delivery::Signer.verify`.
  - It returns 500 for the first `RECEIVER_FAIL_FIRST` requests, then 200.
  - It prints `event_id type sig=ok|bad lag_ms=<now - occurred_at>`.
  - It appends one JSON line per request to `/receiver_logs/receiver.jsonl`, with `received_at`, the headers, `body_sha256`, whether the body parsed, and whether the signature was valid.
- [ ] T073 [P] [US2] Write `docs/adr/0001-transactional-outbox-delivery.md` (ADR-0001), from research R6.
  - **Context**: deliveries must survive restarts and be easy to inspect, and replays and chaos timing must be possible.
  - **Decision**: a Postgres outbox drained by a worker using `SKIP LOCKED`, with at-least-once delivery.
  - **Alternatives**: Sidekiq with Redis; an in-process thread pool.
  - **Consequences**: subscribers MUST deduplicate on `PMS-Event-Id`; the reaper exists for crashed workers.
- [ ] T074 [US2] Add a database-backed delivery metrics collector to `mock_pms/lib/mock_pms/metrics/exposition.rb` (T024). It reports `mock_pms_deliveries_total{status}`, `mock_pms_delivery_attempts_total{outcome}`, `mock_pms_delivery_queue_depth`, and `mock_pms_worker_heartbeat_age_seconds`, all from aggregate queries. Extend `ops_spec.rb` (T013) with a case that checks these metrics appear.

**Checkpoint**: quickstart §5 passes by hand. US1 and US2 together let feature 002 build its
ingestion and idempotency.

---

## Phase 5: User Story 3 - Hit realistic rate limits (Priority: P2)

**Goal**: each client has an exact token-bucket limit on `/v1/*`, shared across every web
instance through Redis. A request over the limit gets 429 with `Retry-After`. If Redis is
unavailable, the API fails closed with 503.

**Independent Test**: one client sends 70 quick requests and gets about 60 `200` responses,
then `429` with `Retry-After ≥ 1`. After waiting, its requests succeed. A second client is
unaffected. When requests alternate between `mock_pms` and `mock_pms_b`, the client still gets
about 60 successes in total. With Redis stopped, `/v1` returns 503 `rate_limiter_unavailable`
(quickstart §6).

### Tests for User Story 3 (write first; they must fail) ⚠️

- [ ] T075 [P] [US3] Write `mock_pms/spec/unit/rate_limit/token_bucket_spec.rb`, against a real Redis, passing `now_ms` explicitly.
  - With capacity 60, 60 calls at the same `now_ms` are allowed, and the 61st is denied with `retry_after_ms = 1000`.
  - At `now_ms + 1000` exactly one more call is allowed.
  - Different client keys are independent.
  - 100 calls from 10 threads at the same `now_ms` allow exactly 60 (atomicity).
  - The key's `PTTL` is no more than the full-refill time plus 1 s.
  - A per-client `rate_limit_per_minute` overrides the default.
- [ ] T076 [P] [US3] Write `mock_pms/spec/requests/rate_limit_spec.rb`.
  - For one token, the request just over the limit to `/v1/properties` gets 429 with the envelope `{"error":{"code":"rate_limited",...}}` and `Retry-After` set to `ceil(retry_after_ms/1000)`, which is at least 1.
  - `/oauth/token`, `/oauth/authorize`, `/admin/*`, `/healthz`, and `/metrics` are never limited (FR-022).
  - After a flush, the 429 and 503 responses are counted in `mock_pms_http_requests_total` under `route="/v1/{resource}"` (the T023 fallback label). The raw path never appears as a label.
  - Scenario activity does not use up any client's tokens.
  - When `MockPms::Redis` raises a connection error, `/v1/*` returns 503 `{"error":{"code":"rate_limiter_unavailable"}}` (fail closed).
  - Invalid or expired tokens still get 401 without spending a token.

### Implementation for User Story 3

- [ ] T077 [US3] Create `mock_pms/lib/mock_pms/rate_limit/token_bucket.lua`, making T075 pass. The script does the following:
  1. `KEYS[1]` is the bucket hash. `ARGV` is `capacity`, `refill_per_ms`, and optionally `now_ms`. When `now_ms` is absent, the script uses `redis.call('TIME')` (R8).
  2. It reads `tokens` and `ts_ms` (a missing bucket counts as full), refills up to capacity, and then either takes a token or computes `retry_after_ms = ceil((1 - tokens) / refill_per_ms)`.
  3. It writes the bucket back with `HSET` and sets `PEXPIRE` to `ceil(capacity/refill_per_ms) + 1000`.
  4. It returns `{allowed(0|1), retry_after_ms, floor(remaining)}`.
- [ ] T078 [US3] Implement `mock_pms/lib/mock_pms/rate_limit/limiter.rb`, `MockPms::RateLimit::Limiter.check(client_id:, capacity:)`. It calls the script through `MockPms::Redis.evalsha`, using key `Redis.key("rl", client_id)` and `refill_per_ms = capacity / 60_000.0`.
- [ ] T079 [US3] Implement `mock_pms/lib/mock_pms/middleware/rate_limiter.rb` and insert it into the rate-limiter slot of `MockPms::App` (T027). It makes T076 pass.
  - It applies only to `/v1/*`.
  - It resolves the bearer token with `OAuth::Service.validate_access_token`. On anything other than `:valid`, it passes the request through so that `V1` returns 401.
  - It uses the client's `rate_limit_per_minute` or `Settings.rate_limit_per_minute`.
  - On deny, it returns 429 with `Retry-After`. On a Redis error, it returns 503 `rate_limiter_unavailable` and logs an error.
  - It increments `mock_pms_rate_limited_total{client_id}` in the metrics buffer.
- [ ] T080 [P] [US3] Create `mock_pms/bin/hammer`. It takes `--token T --requests N --path P [--targets url1,url2]`, alternates requests round-robin across the targets, and prints a count per status and the first `Retry-After` it sees.
- [ ] T081 [P] [US3] Write `docs/adr/0003-redis-token-bucket-rate-limiter.md` (ADR-0003), from research R8.
  - **Context**: FR-021/022 and Constitution X.
  - **Decision**: a Redis Lua token bucket, with Redis `TIME` as the single clock source and fail-closed behavior.
  - **Alternatives**: an in-process `Mutex` bucket (the earlier design, which requires a single process); a Postgres counter; Rack::Attack; an `INCR` fixed window.
  - **Consequences**: Redis is required for `/v1`; the web tier is stateless.

**Checkpoint**: quickstart §6 passes, including the two-instance and Redis-outage checks.

---

## Phase 6: User Story 4 - Turn on chaos to stress the consumer (Priority: P2)

**Goal**: runtime-adjustable chaos covering duplicate, out-of-order, delayed, and malformed
deliveries, plus injected API 500s. The results are reproducible from a seed, regardless of
which process draws the random values.

**Independent Test**: set known chaos rates and generate at least 1,000 events.
`bin/chaos_check` reports every observed rate within ±3 percentage points of its setting. With
every rate at 0, behavior is exactly normal. `--determinism` shows that the same seed produces
identical decision sequences (quickstart §7).

### Tests for User Story 4 (write first; they must fail) ⚠️

- [ ] T082 [P] [US4] Write `mock_pms/spec/unit/chaos/decider_spec.rb`.
  - `Decider.uniform(seed:, stream:, counter:, field:)` equals the first 8 bytes of `HMAC-SHA256(seed, "<stream>:<counter>:<field>")`, read as a big-endian unsigned integer, divided by `2**64`. Check it against a vector computed by hand in the spec.
  - `draw!(:delivery)` runs `UPDATE chaos_counters SET value = value + 1 WHERE stream = 'delivery' RETURNING value`. Draws from 8 threads produce unique, gap-free counters (`:committed`).
  - **Independence**: while one connection holds an open transaction that has drawn from `delivery`, `draw!(:api)` on another connection returns at once and does not block (`:committed`).
  - Calling `PUT` settings resets both `chaos_counters` rows to 0.
  - With `seed: 1`, the same sequence of `decide_delivery` calls gives identical `chaos` hashes across two runs, including when the runs happen in a different process (fork in the spec, `:committed`).
  - With every rate at 0, every decision is `{}`.
  - With rates at 0.10, the observed frequencies over 10 000 decisions are within ±1 percentage point for a fixed seed.
- [ ] T083 [P] [US4] Write `mock_pms/spec/unit/delivery/malformer_spec.rb`.
  - `truncate` returns the first half of the body bytes, which is not parseable JSON.
  - `drop_field` removes `data`.
  - `bad_type` sets `occurred_at` to a number.
  - The signer covers the bytes after malformation, so `Signer.verify` passes on the malformed body.
- [ ] T084 [P] [US4] Write `mock_pms/spec/unit/chaos/application_spec.rb`, covering the recorder and the worker with chaos turned on.
  - **Duplicate**: adds a second `deliveries` row for the same event and client, with `chaos.duplicate_of` set to the first delivery's `id`. Each copy gets its own malform decision.
  - **Out-of-order**: sets `chaos.reorder_hold_s` between 2 and 10 and moves `scheduled_at` later by that amount.
  - **Delay**: sets `chaos.delayed_s` between `delay_min_s` and `delay_max_s` and moves `scheduled_at` later.
  - **Malform**: sets `chaos.malform` to one of `truncate`, `drop_field`, or `bad_type`. The worker sends the malformed body and records `chaos_applied`.
  - The stored `events` row is never changed (FR-025).
- [ ] T085 [P] [US4] Write `mock_pms/spec/requests/chaos_spec.rb`.
  - `GET /admin/chaos` returns the defaults: every rate is 0, `delay_min_s` is 5, `delay_max_s` is 60, and `seed` is 1.
  - `PUT /admin/chaos` with a value out of range returns 422. The ranges are: every rate between 0 and 1; `0 ≤ delay_min_s ≤ delay_max_s ≤ 3600`.
  - A valid `PUT` takes effect immediately, without a restart.
  - With `server_error_rate: 1.0`, `/v1/properties` returns 500 with `code: "chaos_injected"`, while `/oauth/token` and `/admin/*` are not affected. After a flush, these 500s are counted under `route="/v1/{resource}"`.
  - With `server_error_rate: 0`, the `chaos_counters` row for `api` is not incremented. Check that no database write happens per request.

### Implementation for User Story 4

- [ ] T086 [US4] Create migration `mock_pms/db/migrations/006_chaos_settings.rb` for `chaos_settings` and `chaos_counters`. `chaos_settings` holds exactly one row. Enforce that with `id smallint PK CHECK (id = 1)` and insert the default row.
  - `duplicate_rate`, `out_of_order_rate`, `delay_rate`, `server_error_rate`, and `malformed_rate` are `numeric(4,3) NOT NULL DEFAULT 0 CHECK (BETWEEN 0 AND 1)`. Per the data model, they are "each between 0 and 1. **All default to 0**".
  - `delay_min_s integer DEFAULT 5` and `delay_max_s integer DEFAULT 60`, with `CHECK (0 <= delay_min_s AND delay_min_s <= delay_max_s AND delay_max_s <= 3600)`.
  - `seed bigint DEFAULT 1`.
  - `updated_at timestamptz`.
  - **`chaos_counters`**: `stream text PRIMARY KEY CHECK (stream IN ('delivery','api'))` and `value bigint NOT NULL DEFAULT 0`. Insert both rows. Each stream has its own row, so an API draw never waits on a delivery transaction's row lock (R7).
- [ ] T087 [US4] Implement `mock_pms/lib/mock_pms/chaos/settings.rb`, which reads and updates the single row, validates the ranges, and resets both `chaos_counters` rows to 0 on every update, in the same transaction. Also implement `mock_pms/lib/mock_pms/chaos/decider.rb`, making T082 pass.
  - `uniform`: the HMAC-counter derivation from research R7.
  - `draw!(stream)`: `UPDATE chaos_counters SET value = value + 1 WHERE stream = ? RETURNING value`, inside the caller's transaction.
  - `decide_delivery`: returns a `chaos` hash with the fields `duplicate`, `reorder`, `reorder_hold`, `delay`, `delay_s`, `malform`, and `malform_kind`.
  - `api_server_error?`: returns false without touching the database when the rate is 0.
- [ ] T088 [US4] Implement `mock_pms/lib/mock_pms/delivery/malformer.rb`, making T083 pass. Then wire chaos into `Events::Recorder#chaos_for` (T064) and `Delivery::Worker` (T066):
  - the recorder creates the duplicate row and adjusts `scheduled_at`;
  - the worker applies the `malform` setting before signing and copies `chaos` into `delivery_attempts.chaos_applied`.

  This task makes T084 pass.
- [ ] T089 [US4] Implement `mock_pms/lib/mock_pms/middleware/chaos_errors.rb` and insert it into the chaos slot of `MockPms::App`, **after** the rate limiter, so injected 500s still count against the limit. It applies only to `/v1/*` and returns 500 `{"error":{"code":"chaos_injected","message":...}}`. Add `GET` and `PUT /admin/chaos` to `mock_pms/lib/mock_pms/api/admin.rb`. This task makes T085 pass.
- [ ] T090 [US4] Create `mock_pms/bin/chaos_check`.
  - **Rates**: `--receiver-log PATH` joins the receiver JSONL log with `/admin/deliveries` and `/admin/events` through the admin API, computes each rate using the definitions in the research R7 table, and prints observed against configured values. It exits non-zero if any rate differs by more than 3 percentage points.
  - **Volume**: `--generate N` triggers bursts until N events exist.
  - **Determinism**: `--determinism` runs the following twice:
    1. `POST /admin/reset`.
    2. Register a client through `POST /admin/clients`.
    3. Approve it by POSTing the `/oauth/authorize` form as a seeded operator (no browser).
    4. `PUT /admin/chaos` with `seed: 1`.
    5. Run one scenario.

    It then compares the ordered `chaos` hashes from both runs, and exits non-zero on any difference.

**Checkpoint**: quickstart §7 passes. The chaos demo in the finish line (kickoff §6) can be
reproduced.

---

## Phase 7: User Story 5 - Replay events and trigger scenarios (Priority: P3)

**Goal**: an admin can replay one event, or every event in a time range, with the original
event IDs. The `month_end_burst` scenario creates a realistic payment spike. Admin
side-effecting calls are idempotent, and reset brings back the seed state.

**Independent Test**: a replayed event arrives again with the same `PMS-Event-Id` and
`PMS-Replay: true`. A range replay redelivers every event in `occurred_at` order. With chaos
off, the month-end burst covers at least 70% of active leases, delivered within 2 minutes. The
same `Idempotency-Key` returns the same `run_id`. Admin calls without the token get 401
(quickstart §8).

### Tests for User Story 5 (write first; they must fail) ⚠️

- [ ] T091 [P] [US5] Write `mock_pms/spec/unit/scenarios/month_end_burst_spec.rb`.
  - `MonthEndBurst.run!(share: 0.8, window_s: 120, operator: nil)` records a payment against the open rent charge for `ceil(share × active leases with an open charge)` leases.
  - Each payment's `received_at` and its event's `occurred_at` are spread evenly across the `window_s` before now.
  - It writes `payment_applications`, and emits one `payment.created` per payment through the recorder, so chaos still applies.
  - The default `share` is 0.8, which keeps SC-008's 70% minimum.
  - `operator_id` limits the scenario to one operator.
- [ ] T092 [P] [US5] Write `mock_pms/spec/requests/replay_spec.rb`.
  - **Single replay**: `POST /admin/events/{id}/replay` with `{"client_id"}` returns 202 and a `Delivery` with `replay: true`, for the original event.
  - **Single replay refusals**: it returns 409 when the client has no active grant for the event's operator, or no `subscriber_url`.
  - **Range replay**: `POST /admin/replays` with `{client_id, from, to, types?}` returns 202 with `{queued: n}`. It covers `occurred_at >= from AND < to`, and deliveries are scheduled in `occurred_at` order. It returns 409 under the same conditions as the single replay.
  - **Replay deliveries**: the worker sends `PMS-Replay: true` with the original `PMS-Event-Id`, `type`, `occurred_at`, and payload (FR-029).
  - **Seeded events**: they can be replayed even though they never had a delivery.
- [ ] T093 [P] [US5] Write `mock_pms/spec/requests/reset_spec.rb`.
  - `POST /admin/reset` with `{seed: 42, anchor_date: "2026-10-20"}` returns `{seed, anchor_date, data_digest}`, and the digest equals the one from `bin/reseed --seed 42 --anchor 2026-10-20`.
  - Clients, grants, and deliveries are cleared, and both `chaos_counters` rows go back to 0. Redis metric hashes, `admin_idempotency_keys`, and earlier `seed_runs` rows are kept.
  - The endpoint requires the admin token.
  - **Idempotent replay**: repeat the reset with the same `Idempotency-Key`. It returns the stored `data_digest` and does **not** reseed, so `seed_runs` gains exactly one new row across both calls.

### Implementation for User Story 5

- [ ] T094 [US5] Implement `mock_pms/lib/mock_pms/scenarios/month_end_burst.rb`, register it in the scenario registry (T070), and make T091 pass.
- [ ] T095 [US5] Implement `mock_pms/lib/mock_pms/events/replayer.rb`, which provides `replay_one!(event:, client:)` and `replay_range!(client:, from:, to:, types:)`.
  - Both check for an active grant and a `subscriber_url`, raising a 409 error otherwise.
  - They insert `deliveries` rows with `replay: true`, with `chaos` decided by `Decider` as usual. For a range replay, `scheduled_at` is staggered by 1 ms per event so the original order is kept.
  - Then add `POST /admin/events/{event_id}/replay` and `POST /admin/replays` (wrapped in `with_idempotency`) to `mock_pms/lib/mock_pms/api/admin.rb`, and make the worker send the `PMS-Replay: true` header. This makes T092 pass.
- [ ] T096 [US5] Add `POST /admin/reset` to `mock_pms/lib/mock_pms/api/admin.rb`. It calls `Seed::Reset.run!` (T046), resets the chaos counters, and makes T093 pass.

**Checkpoint**: quickstart §8 passes. All five user stories work independently.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: end-to-end telemetry checks, CI completeness, documentation, and a final
check of the constitution.

- [ ] T097 [P] Write `mock_pms/spec/integration/observability_spec.rb`.
  - Run a scenario and one request of each kind.
  - Capture the stdout log lines and check that every one is JSON with `service.name` and `code.function.name`, and that none contains a raw token, client secret, signing secret, password, or tenant contact value (FR-031).
  - Check that `/metrics` contains the request, delivery, rate-limit, and dropped-metrics families, plus `target_info`.
  - **Burst timing** (`:committed, :slow`): run `MonthEndBurst` with the default share, plus the worker loop polling every 1 s, against a throwaway receiver. Every `payment.created` is delivered within 120 s (SC-008).
- [ ] T098 Add a `telemetry-smoke` job to `.github/workflows/ci.yml`, running after `test` (`needs: test`).
  1. Copy `.env.example` to `.env`.
  2. Run `docker compose up -d --wait postgres redis mock_pms mock_pms_worker otel-collector openobserve`.
  3. Run `docker compose exec -T mock_pms bin/setup`.
  4. `POST /admin/scenarios/tenant_move_out`.
  5. Poll OpenObserve's search API (`POST /api/default/_search` with Basic auth) for up to 60 s, looking for a log where `service_name = 'mock_pms-worker'` and `code_function_name` is not empty, and for the metric stream `mock_pms_http_requests_total` with `service_name = 'mock_pms-web'` and a non-empty `service_version`.
  6. Fail the job if either is missing. On failure, print `docker compose logs`.

  Put the polling in `mock_pms/bin/telemetry_smoke`, which reads the OpenObserve URL and credentials from the environment. Keep the OpenObserve field names (`service_name`, `service_version`, `code_function_name`) in one `FIELD_NAMES` constant at the top of the file, because they are unverified until T101 (R16).
- [ ] T099 [P] Write `mock_pms/README.md`. It covers what the mock is (a test harness, not a product); how to run it (link to `specs/001-mock-pms/quickstart.md`); the settings table, taken from `.env.example`; the operator logins (`bin/seed_report`); the contracts (links to `openapi.yaml` and `webhooks.md`); and ADRs 0001–0004.
- [ ] T100 [P] Add a "Mock PMS" section to the root `README.md`: a two-line description, the `docker compose up` quick start, and a link to `mock_pms/README.md`.
- [ ] T101 Run every quickstart.md section (§1–§9) by hand against Docker Compose on the Windows development machine, using Git Bash.
  - Record the results and any deviations in `docs/ai-build-log.md`.
  - Fix defects in the code. Change `quickstart.md` only where it is genuinely wrong.
  - In particular, confirm that the Collector reads logs from `/var/lib/docker/containers` under Docker Desktop (research R16). If it can't, record the failure and switch to the documented alternative in an ADR-0004 amendment.
  - Confirm the OpenObserve field names that `bin/telemetry_smoke` assumes: `service_name`, `service_version`, and `code_function_name` (dots flattened to underscores, R16). Check them with one search in the UI against the pinned OpenObserve version. If they differ, update the field-name constant in `bin/telemetry_smoke` and record the actual names in R16 and `docs/ai-build-log.md`.
  - Confirm that `otelcol_exporter_send_failed_*` appears under job `otel-collector` in OpenObserve. Stop OpenObserve for 30 s, start it again, and check that the counter is non-zero, so drops are counted (Constitution VI).
- [ ] T102 Do a constitution compliance pass over the finished code and record the result in `docs/ai-build-log.md`.
  - **I**: no updates or deletes on `events`, `delivery_attempts`, or `reversals`.
  - **II**: every row of the plan's idempotency-key table is enforced.
  - **III**: every R13 unit had its test written first.
  - **VI/VII**: telemetry fields and redaction are correct.
  - **VIII**: the Gemfile matches the plan's Dependencies table exactly.
  - **X**: no process-local shared state (search for class-level mutable `@@`/constants holding state, and `Mutex`-guarded globals other than the metrics buffer); no distributed locks.
  - Fix any violation, or justify it in plan.md Complexity Tracking.
- [ ] T103 Append the session summary to `docs/ai-build-log.md`: what was done, what was blocked, decisions made, and the next step (feature 002: `/speckit-specify` for connection and webhook ingestion).

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)** has no dependencies.
- **Foundational (Phase 2)** depends on Setup, and **blocks every user story**.
- **US1 (Phase 3)** depends on Foundational. It is the MVP.
- **US2 (Phase 4)** depends on Foundational and **US1**: it needs the business tables, OAuth grants and clients (fan-out), and the presenters (T048).
- **US3 (Phase 5)** depends on Foundational and **US1**, because it needs access-token validation and clients. It is independent of US2.
- **US4 (Phase 6)** depends on **US2**, because chaos acts on events and deliveries. The API-500 part (T089) also uses US1's `/v1`.
- **US5 (Phase 7)** depends on **US2**, for events, deliveries, and the scenario registry. Replay picks up chaos automatically if US4 is done, and works without it.
- **Polish (Phase 8)** depends on every story the release includes.

### Story completion graph

```
Setup ─► Foundational ─► US1 ─┬─► US2 ─┬─► US4
                              │        └─► US5
                              └─► US3
```

### Order within each phase

- Test tasks come first and MUST fail before their implementation tasks start (Constitution III).
- Then migrations, then models, then services and domain logic, then endpoints and binaries, then the ADR.
- Tasks that edit the same file are kept in order: `api/admin.rb` (T050 → T070 → T089 → T095 → T096), `app.rb` (T027 → T042/T049 mounts → T079 → T089), `events/recorder.rb` (T064 → T088), `delivery/worker.rb` (T066 → T088 → T095), and `seed/*` (T044/T045 → T068).

### Parallel opportunities

- **Setup**: T003, T004, T005, T007, T008, T009, and T010 can run in parallel after T001 and T002. T006 waits for T003.
- **Foundational**: tests T011–T014 can run in parallel. Then T015, T016, T019, T021, T029, and T030 can run in parallel. T017 → T022/T023 → T024 → T025 → T026 → T027 → T028 run in order.
- **US1**: tests T031–T036 can run in parallel. T039 and T040 can run in parallel after the migrations (T037, T038). T043, T047, T048, and T051 can run in parallel with the OAuth work.
- **US2**: tests T052–T058 can run in parallel. T061, T062, T063, T065, T072, and T073 can run in parallel.
- **US3**: T075 and T076 can run in parallel, and so can T080 and T081. **US3 can be built in parallel with US2** once US1 is done.
- **US4/US5**: their test tasks can run in parallel. **US4 and US5 can be built in parallel** once US2 is done; they only share `api/admin.rb`, which is kept in order as above.

---

## Parallel Example: User Story 1

```bash
# All US1 tests together (they must fail):
Task: "OAuth lifecycle unit spec in mock_pms/spec/unit/oauth/lifecycle_spec.rb"
Task: "Pagination stability spec in mock_pms/spec/unit/pagination_spec.rb"
Task: "Seed determinism spec in mock_pms/spec/unit/seed/determinism_spec.rb"
Task: "OAuth request spec in mock_pms/spec/requests/oauth_spec.rb"
Task: "/v1 request spec in mock_pms/spec/requests/v1_spec.rb"
Task: "Admin clients/grants request spec in mock_pms/spec/requests/admin_clients_spec.rb"

# After migrations T037/T038, the models together:
Task: "Business models in mock_pms/lib/mock_pms/models/{operator,property,...}.rb"
Task: "OAuth models in mock_pms/lib/mock_pms/models/{client,grant,...}.rb"
```

## Parallel Example: User Story 2

```bash
Task: "Signature vector fixture in mock_pms/spec/fixtures/signature_vector.json (via openssl)"
Task: "Signer spec in mock_pms/spec/unit/delivery/signer_spec.rb"
Task: "Retry schedule spec in mock_pms/spec/unit/delivery/retry_schedule_spec.rb"
Task: "Recorder spec in mock_pms/spec/unit/events/recorder_spec.rb"
Task: "Worker spec in mock_pms/spec/unit/delivery/worker_spec.rb"
```

---

## Implementation Strategy

### MVP first (User Story 1 only)

1. Phase 1: Setup.
2. Phase 2: Foundational (this blocks everything else).
3. Phase 3: US1.
4. **Stop and validate**: run quickstart §1–§4. Feature 002's OAuth connection and reconciliation work can start here.

### Incremental delivery

1. Setup + Foundational make the foundation ready, with CI green.
2. US1 adds OAuth and the read API: the MVP.
3. US2 adds signed webhooks, which unblocks feature 002's ingestion.
4. US3 adds rate limits. It can be built alongside US2.
5. US4 adds chaos, which enables the resilience demo.
6. US5 adds replay, the month-end burst, and reset.
7. Polish adds the telemetry-smoke job in CI, the docs, and the compliance pass.

Each increment leaves `bundle exec rspec` and `rubocop` green and is committed in small steps.
Merge `001-mock-pms` only after Phase 8, with CI green, before starting feature 002.

---

## Notes

- [P] tasks touch different files and don't depend on unfinished tasks.
- A [Story] label traces a task back to spec.md.
- Verify each test fails before implementing what it covers. Never weaken a test to make it
  pass.
- Commit after each task or logical group, and add an entry to `docs/ai-build-log.md` at the
  end of every session.
- **Refinements to the plan's source tree.** These came up while breaking the work into
  tasks:
  - `/v1` resource shapes live in `lib/mock_pms/presenters/`, which both `/v1` and the event
    serializer use;
  - `rate_limit/limiter.rb` sits next to the Lua script;
  - `events/replayer.rb`, `scenarios/base.rb`, `seed/reset.rb`, `delivery/retry_schedule.rb`,
    `middleware/request_metrics.rb`, `api/errors.rb`, `api/admin_base.rb`, `clock.rb`, and
    `ids.rb` are added;
  - `bin/telemetry_smoke` is added.
