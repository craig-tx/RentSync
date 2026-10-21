# Quickstart & Validation: Mock PMS

This guide checks the feature end to end, mapped to the spec's user stories and success
criteria. The interfaces are defined in [contracts/openapi.yaml](contracts/openapi.yaml) and
[contracts/webhooks.md](contracts/webhooks.md).

## Prerequisites

- Docker Desktop with Compose v2.
- A bash shell. On Windows, use Git Bash; the examples use `cp`, `$ADMIN_TOKEN`, and `grep`.
- **Git Bash only:** prefix commands that pass a container path, such as
  `/receiver_logs/receiver.jsonl`, with `MSYS_NO_PATHCONV=1`. Otherwise Git Bash rewrites the
  path into a Windows path before Docker sees it.
- Tools inside the container run with `bundle exec`, for example
  `docker compose exec mock_pms bundle exec bin/seed_report`.
- `curl`.
- Optional: `jq`.
- Load the admin token into your shell: `export $(grep ADMIN_TOKEN .env)`.

## 1. Start the harness

```bash
cp .env.example .env                      # ADMIN_TOKEN, SEED=42, ACCESS_TOKEN_TTL=300, etc.
docker compose up -d postgres redis mock_pms mock_pms_worker otel-collector openobserve
docker compose exec mock_pms bundle exec bin/setup  # create databases, migrate, seed (SEED, SEED_ANCHOR_DATE)
curl -s localhost:4001/healthz
```

**Expected**: `{"status":"ok","db":"ok","redis":"ok","worker_heartbeat_age_s":<30}`. Seeding takes under
1 minute (SC-002). The web and worker processes also run any pending migrations when they start,
under a Postgres advisory lock.

`.env.example` ships an OpenObserve password that meets its policy (8–128 characters, with
upper case, lower case, a digit and a special character). OpenObserve refuses to start with a
weaker password.

## 2. Run the test suite

```bash
docker compose run --rm mock_pms bundle exec rspec
docker compose run --rm mock_pms bundle exec rubocop
```

**Expected**: all tests pass, and RuboCop reports no offenses. This covers the test-first
units in research R13 and the end-to-end delivery spec. The same two commands run in
`.github/workflows/ci.yml` on every pull request (R15).

## 3. Seed determinism (FR-013, SC-002)

```bash
docker compose exec mock_pms bundle exec bin/reseed --seed 42 --anchor 2026-10-20   # prints data_digest
docker compose exec mock_pms bundle exec bin/reseed --seed 42 --anchor 2026-10-20   # same digest
docker compose exec mock_pms bundle exec bin/reseed --seed 7  --anchor 2026-10-20   # different digest
```

`bundle exec bin/seed_report` prints counts by operator and the payment-behavior mix. **Expected**:

- 3 operators, about 50 properties, and about 60 leases;
- on-time, late, partial, NSF-reversal, and unpaid months all present;
- at least 3 leases with status `ended_early`.

## 4. Connect and read (User Story 1, SC-001)

1. **Register a client.** The response returns `client_id`, `client_secret`, and
   `signing_secret` once only.

   ```bash
   curl -s -X POST localhost:4001/admin/clients \
     -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
     -d '{"name":"local","redirect_uris":["http://localhost:9999/cb"],"subscriber_url":"http://receiver:9999/webhooks"}'
   ```

2. **Approve access.** Open the following address in a browser, sign in as a seeded operator
   (listed by `bin/seed_report`), and click **Approve**:
   `http://localhost:4001/oauth/authorize?response_type=code&client_id=<id>&redirect_uri=http://localhost:9999/cb&state=xyz`.
   Copy the `code` from the redirect URL. The redirect target does not need to be running.

3. **Exchange the code for tokens.**

   ```bash
   curl -s -u <client_id>:<client_secret> localhost:4001/oauth/token \
     -d grant_type=authorization_code -d code=<code> -d redirect_uri=http://localhost:9999/cb
   ```

4. **Page through the data.** Call `GET /v1/payments?limit=50` with
   `Authorization: Bearer <access_token>`, then follow `next_cursor` until it is `null`.

**Expected**:

- Repeating the step 3 exchange with the same code returns `400 invalid_grant`.
- Only that operator's records appear.
- After 5 minutes, `/v1/*` returns `401` with `error_description="token expired"`.
- Exchanging the refresh token (`grant_type=refresh_token`) returns a new pair. Reusing the old
  refresh token returns `400 invalid_grant`.
- After `POST /admin/grants/{id}/revoke`, both tokens are rejected immediately with
  `"token invalid"`.

## 5. Signed webhooks (User Story 2, SC-003, SC-004)

The receiver runs as the `receiver` Compose service, on the Compose network at
`http://receiver:9999` (research R14). Start it with `docker compose up`, not `docker compose run`:
`run` does not register the `receiver` DNS alias, so deliveries fail with connection errors.

```bash
RECEIVER_SECRET=<signing_secret> docker compose --profile tools up receiver
# In a second terminal:
curl -s -X POST localhost:4001/admin/scenarios/tenant_move_out -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" -d '{}'
curl -s -X POST localhost:4001/admin/scenarios/nsf_wave       -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" -d '{"count":2}'
```

`bin/test_receiver` checks every `PMS-Signature`, prints one line per delivery (event ID, type,
whether the signature is valid, how far it lagged `occurred_at`). It also writes a JSONL log to
the shared `receiver_logs` volume, which step 7 reads. **Expected**:

- `lease.updated`, `tenant.moved_out`, and `payment.reversed` deliveries arrive within 5 s,
  each with a valid signature.
- Restart the receiver with `RECEIVER_FAIL_FIRST=3` and trigger again. `PMS-Delivery-Attempt` reaches 4
  with the same `PMS-Event-Id`, and `GET /admin/deliveries?event_id=...` shows all 4 attempts.

## 6. Rate limits (User Story 3, SC-006)

```bash
docker compose exec mock_pms bundle exec bin/hammer --token <access_token> --requests 70 --path /v1/properties
```

**Expected**: about 60 requests get `200`, then `429` responses follow, each with
`Retry-After` of at least 1. After waiting `Retry-After` seconds, a request gets `200`. A
second client's token is unaffected throughout.

**The limit is shared across instances.** This checks that the web tier is stateless (research
R8):

```bash
docker compose --profile tools up -d mock_pms_b   # second web instance, same image, no host port
```

Rerun `bin/hammer` with `--targets http://mock_pms:4001,http://mock_pms_b:4001`, which
alternates requests between the two instances. **Expected**: the client still gets about 60 successes in total, not about
120.

**Redis outage.** Run `docker compose stop redis`. **Expected**: `/v1/*` returns `503`
`rate_limiter_unavailable`, and `/healthz` returns `503` with `"redis":"down"`. Run
`docker compose start redis`, and both recover without restarting `mock_pms`.

## 7. Chaos (User Story 4, SC-005)

```bash
curl -s -X PUT localhost:4001/admin/chaos -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"duplicate_rate":0.10,"out_of_order_rate":0.10,"delay_rate":0.05,"delay_min_s":2,"delay_max_s":8,"malformed_rate":0.05,"server_error_rate":0.10,"seed":1}'
curl -s -X POST localhost:4001/admin/scenarios/month_end_burst -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d '{"share":1.0,"window_s":60}'
# Generate at least 1,000 events (alternates month-end bursts with NSF waves)
C="-e ADMIN_TOKEN=$ADMIN_TOKEN -e MOCK_PMS_URL=http://mock_pms:4001"
docker compose exec $C mock_pms bundle exec bin/chaos_check --generate 1200
# Wait for the queue to drain, then measure. --client-id limits it to the receiver client;
# --token measures injected 500s (use a client whose rate_limit_per_minute is high enough).
MSYS_NO_PATHCONV=1 docker compose exec $C mock_pms bundle exec bin/chaos_check \
  --receiver-log /receiver_logs/receiver.jsonl --client-id <client_id> --token <access_token> --api-requests 1000
```

`bin/chaos_check` compares the receiver log with `/admin/deliveries` and `/admin/events`, and
prints each observed rate next to its configured rate. **Expected**: every rate is within
±3 percentage points. The measurement definitions are in research R7.

Then set every rate to 0 and repeat the burst. **Expected**: no duplicates, no reordering, no
malformed bodies, and no injected 500s (FR-024).

Finally, run `bin/chaos_check --determinism`. It checks FR-026 like this:

1. It resets the harness. A reset clears clients and grants as well as data.
2. It registers a client through the admin API and approves it by POSTing the
   `/oauth/authorize` form as a seeded operator. No browser is needed.
3. It runs the same scenario with `seed:1`.
4. It repeats steps 1–3.
5. It checks that both runs produced identical `deliveries.chaos` decision sequences.

Any demo script that runs after a reset has to register its client and approve it the same way.
`--determinism` leaves its own chaos settings and its client in place, so set the chaos rates
back to 0 afterwards.

## 8. Replay and scenarios (User Story 5, SC-008)

- `POST /admin/events/{evt}/replay` with `{"client_id":...}` makes the receiver log the
  **same** `PMS-Event-Id`, with `PMS-Replay: true` set.
- `POST /admin/replays` with a time range redelivers every event in that range, in
  `occurred_at` order.
- With chaos off, `month_end_burst` (default `share` 0.8) reports `events_created` of at least
  70% of active leases. The receiver logs all of them within 2 minutes.
- Sending the same `Idempotency-Key` twice on a scenario call returns the same `run_id`, and no
  second set of events is created.
- Any `/admin/*` call without the admin token returns `401`.

## 9. Observability and safety (FR-030, FR-031)

```bash
curl -s localhost:4001/metrics | grep mock_pms_
docker compose logs mock_pms mock_pms_worker | grep -Ei 'client_secret|signing_secret|password|access_token'
```

**Expected**:

- `/metrics` shows request counters and delivery outcome counters.
- With `mock_pms_b` running (step 6), wait at least 5 s after the hammer run, which is one
  flush interval. Then `/metrics` from `mock_pms` and `mock_pms_b` (fetched with
  `docker compose exec mock_pms_b curl -s localhost:4001/metrics`) report the same
  `mock_pms_http_requests_total` values. Those values equal the total number of requests across
  both instances (Constitution X, research R12).
- The log search returns nothing, apart from field names with `[REDACTED]` values.
- Every log line is JSON and has `service.name`, `code.function.name` (for example
  `MockPms::Delivery::Worker#deliver`), and `correlation_id`.

**Telemetry in OpenObserve (Constitution VI, research R16).** Open `http://localhost:5080` and
sign in with `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD` from `.env`. **Expected**:

- Under **Logs** (stream `default`), entries from both `mock_pms-web` and `mock_pms-worker`
  appear within about 30 s. Each one has `code.function.name`, `correlation_id`, and the
  resource attributes `service.name`, `service.version`, `deployment.environment`, and
  `service.instance.id`.
- Filtering on one scenario's `correlation_id` shows its web, worker, and delivery lines
  together.
- Under **Metrics**, `mock_pms_http_requests_total` and the delivery outcome counters appear,
  and their values match `curl localhost:4001/metrics`.
- No log entry contains a raw token, secret, password, or tenant contact detail.
- **Resilience**: run `docker compose stop openobserve otel-collector`, then trigger a
  scenario. `/v1` requests and webhook deliveries keep working, and logs are still in
  `docker compose logs`. Run `docker compose start otel-collector openobserve`; new telemetry
  appears again.
- The `X-Correlation-Id` the receiver logs for a scenario's events equals that scenario's
  `run_id`.
