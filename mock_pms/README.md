# Mock PMS

A simulated property management system (PMS) that RentSync's integration layer develops and demonstrates against. **It is a test harness, not a product**: small, realistic, and deliberately hostile when asked to be.

It provides:

- **An OAuth 2.0 authorization server:** authorization code with optional PKCE S256, rotating refresh tokens, and 5-minute access tokens. An expired token is distinguished from an invalid one.
- **A read-only, operator-scoped `/v1` API** for properties, tenants, leases, charges and payments, with keyset pagination and filters.
- **A deterministic 12-month seed portfolio:** 3 operators, 50 properties and 60 leases. It covers on-time, late and partial payments, NSF reversals and move-outs, plus the events that history would have produced.
- **Signed webhooks** (`PMS-Signature`, HMAC-SHA256) for `payment.created`, `payment.reversed`, `lease.updated` and `tenant.moved_out`. They are delivered at least once from a Postgres outbox, with retries and a full attempt log.
- **Per-client rate limits** (429 with `Retry-After`), shared exactly across instances through Redis.
- **Seeded, reproducible chaos:** duplicates, reordering, delays, malformed bodies, and injected `/v1` 500s.
- **An admin API** for clients, grants, replays, scenarios and resets, with `Idempotency-Key` support.

## Run it

Follow [specs/001-mock-pms/quickstart.md](../specs/001-mock-pms/quickstart.md). In short:

```bash
cp .env.example .env
docker compose up -d postgres redis mock_pms mock_pms_worker otel-collector openobserve
docker compose exec mock_pms bundle exec bin/setup
curl -s localhost:4001/healthz
```

The API runs on <http://localhost:4001> and OpenObserve on <http://localhost:5080>. Sign in to OpenObserve with `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD` from `.env`.

Run the tests with `docker compose run --rm mock_pms bundle exec rspec` and lint with `docker compose run --rm mock_pms bundle exec rubocop`.

## Operator logins

`docker compose exec mock_pms bundle exec bin/seed_report` prints them, along with the behaviour mix. The seeded logins are `lonestar`, `prairie` and `bluebonnet`, each with the password `<login>-pass`.

## Processes and tools

| Command | Purpose |
|---|---|
| `bundle exec puma -C config/puma.rb` | Web API. Stateless, so any worker or container count is safe |
| `bin/delivery_worker` | Drains the webhook outbox. Any number can run (`SKIP LOCKED`) |
| `bin/setup` | Creates the databases, migrates and seeds |
| `bin/reseed --seed N --anchor YYYY-MM-DD` | Regenerates the seed data and prints its digest |
| `bin/seed_report` | Counts, behaviour mix, move-outs and logins |
| `bin/test_receiver --port 9999` | A webhook receiver that checks signatures and writes a JSONL log |
| `bin/hammer` | Rate-limit probe, round-robin across `--targets` |
| `bin/chaos_check` | Observed vs configured chaos rates, `--generate`, `--determinism` |
| `bin/telemetry_smoke` | Checks that logs and metrics reach OpenObserve (CI) |

## Settings

Every setting is listed in [`.env.example`](../.env.example).

| Variable | Default | Meaning |
|---|---|---|
| `ADMIN_TOKEN` | — (required) | Bearer token for `/admin/*` |
| `DATABASE_URL`, `TEST_DATABASE_URL` | Compose Postgres | Dedicated `mock_pms` databases |
| `REDIS_URL` | Compose Redis | Rate-limit buckets and metric totals |
| `SEED`, `SEED_ANCHOR_DATE` | `42`, today | Seed inputs. A fixed anchor gives identical data on any day |
| `ACCESS_TOKEN_TTL`, `REFRESH_TOKEN_TTL` | `300`, `2592000` | Token lifetimes in seconds |
| `RATE_LIMIT_PER_MINUTE` | `60` | Default limit per client. Clients can override it |
| `RETRY_BASE_SECONDS`, `MAX_ATTEMPTS` | `2`, `8` | Webhook backoff (`base × 2^(n−1)`, ±10%) |
| `METRICS_FLUSH_INTERVAL_S` | `5` | How often metric deltas are flushed to Redis |
| `DEPLOYMENT_ENVIRONMENT` | `local` | Telemetry resource attribute |
| `OPENOBSERVE_USER`, `OPENOBSERVE_PASSWORD` | example values | Collector export credentials |

## Contracts

- HTTP API: [contracts/openapi.yaml](../specs/001-mock-pms/contracts/openapi.yaml)
- Webhooks, including the signature scheme and test vector: [contracts/webhooks.md](../specs/001-mock-pms/contracts/webhooks.md)

## Telemetry

Logs are JSON lines on stdout, using OpenTelemetry field names: `service.name`, `code.function.name`, `correlation_id`, and so on. Metrics are Prometheus text on `/metrics`, with cluster-wide totals held in Redis. An OpenTelemetry Collector forwards both to OpenObserve over OTLP. The services themselves have no OpenTelemetry dependencies.

## Design decisions

- [ADR-0001](../docs/adr/0001-transactional-outbox-delivery.md): transactional outbox for webhook delivery
- [ADR-0002](../docs/adr/0002-hand-written-oauth-server.md): hand-written OAuth server with hashed tokens
- [ADR-0003](../docs/adr/0003-redis-token-bucket-rate-limiter.md): Redis token-bucket rate limiter
- [ADR-0004](../docs/adr/0004-otlp-collector-bridge.md): OTLP through a Collector bridge
