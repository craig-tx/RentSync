# Research: PMS Connection and Webhook Ingestion

Each entry records a decision, why it was made, and what else was considered. The PMS
contract referred to throughout is feature 001's
[openapi.yaml](../001-mock-pms/contracts/openapi.yaml) and
[webhooks.md](../001-mock-pms/contracts/webhooks.md).

## R1. A new `/api` service, built like the mock PMS

**Decision**: RentSync is a new Ruby service in `/api`: Grape on Puma, Sequel with `pg`, and
`redis`. It runs as two processes from one image, `api` (web) and `api_worker`. It reuses the
mock PMS's patterns: the JSON logger with OTel field names and redaction, the buffered Redis
metric flusher, the correlation-ID middleware, `/healthz` with Central-time fields, and
migrations at boot under an advisory lock. Those modules are **copied** into `api/lib/rentsync/`
and adapted, not shared.

**Rationale**: the two services are deliberately separate systems: one plays a vendor and the
other plays the product. A shared gem would couple their release cycles and Docker build
contexts for about 300 lines of code. The copies are small, already tested, and each gets its
own specs.

**Alternatives**: a shared path gem under `/lib` (rejected: couples both images' build contexts
and versions); Rails (ruled out by the kickoff stack).

## R2. Background work uses Postgres claims, not Sidekiq

**Decision**: this feature adds no Sidekiq. Recording a webhook happens **inside the request**,
because the PMS must get a success response only once the event is durable (FR-011). The
remaining background work is reconciliation, token renewal before it, and the daily purge of
old receipts. One `api_worker` loop runs it all and claims work from Postgres:

- Due reconciliations are claimed with
  `UPDATE pms_connections SET lease_until = now() + interval '5 minutes' WHERE id IN (SELECT id ... WHERE next_reconcile_at <= now() AND (lease_until IS NULL OR lease_until < now()) FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING ...`.
  Any number of workers is safe, and a crashed worker's lease expires (Constitution X).
- The daily purge holds a row lease in a one-row `maintenance_leases` table in the same way.

**Rationale**: there is no asynchronous processing of events yet; the ledger (next feature)
adds it. A periodic scheduler for Sidekiq needs another gem (`sidekiq-cron`) or Sidekiq
Enterprise. Postgres claims are already proven in this repo (feature 001 ADR-0001), add no
dependency (Constitution VIII), and cost no memory on a 1 GiB host (R14). **ADR-0009** records
this, and the point at which to revisit it: when the ledger needs a high-volume job queue.

**Alternatives**: Sidekiq plus `sidekiq-cron` (two gems and a process for three periodic jobs);
recording webhooks asynchronously through a queue (rejected: acknowledging before the event is
durable breaks FR-011).

## R3. Webhook receiving: verify, then parse, then record once

**Decision**: `POST /webhooks/pms` is a plain Rack endpoint mounted before Grape, so it reads the
**exact raw body bytes** before anything parses them. In order:

1. Read the body, up to 256 KiB (larger: reject `body_too_large`).
2. Parse `PMS-Signature` (`t=…,v1=…`), recompute HMAC-SHA256 over `"#{t}.#{body}"` with the
   PMS client's signing secret, and compare in constant time (`OpenSSL.fixed_length_secure_compare`
   after a length check). Failure: `bad_signature` (or `missing_signature`).
3. Reject `|now − t| > 300 s` as `stale_timestamp`.
4. Parse JSON and validate the envelope: `id`, `type` (one of the four), `occurred_at` (an
   ISO 8601 string), `operator_id`, and `data.object` (an object). Failure: `malformed_body`.
   `PMS-Event-Id` must equal `id` (else `malformed_body`).
5. Find the active connection for `(pms_client, operator_id)`. None at all for that operator:
   `unknown_operator`; only disconnected or reauth-needed ones: `no_active_connection`.
6. `INSERT INTO raw_events ... ON CONFLICT DO NOTHING RETURNING id`, in one transaction with
   the receipt row. A conflict means a duplicate: if the stored `payload_sha256` equals this
   body's, the outcome is `duplicate`; otherwise `conflicting_duplicate` (recorded as a
   rejection, first version stands).
7. Commit, then answer. `recorded` and `duplicate` get `200`. Signature and timestamp failures
   get `401`; every other rejection gets `422`. Any unexpected error gets `500`, so the PMS
   retries.

Every delivery, accepted or not, writes one **receipt** row (R10). A rejected body is never
stored, only its length and SHA-256, so an attacker cannot use the endpoint to store content.

**Rationale**: HMAC before parsing is Constitution VII. The mock signs malformed bodies validly,
so steps 4–5 are what reject chaos malformations (webhooks.md). A unique constraint, not code,
deduplicates (Constitution II).

**On retries of malformed deliveries**: the mock decides malformation once per delivery, so its
retries resend the same bad body until the attempt limit. Each attempt is recorded as its own
rejection. That is noisy but honest, and the duplicate-delivery chaos usually brings a good
copy. Answering `200` to stop retries was rejected: it would acknowledge something not recorded.

## R4. One record per business fact, whichever path sees it first

**Decision**: `raw_events` has two unique keys per PMS client:

- `(pms_client_id, event_id)`: the PMS event ID for webhooks. Reconciliation writes a
  synthetic, deterministic ID: `recon:payment.created:<pay_id>` or
  `recon:payment.reversed:<pay_id>`.
- `(pms_client_id, business_key)`, partial on `business_key IS NOT NULL`: for payment facts only,
  `payment.created:<pay_id>` and `payment.reversed:<pay_id>`. `lease.updated` and
  `tenant.moved_out` have no business key, because one lease legitimately produces many.

A webhook that arrives after reconciliation recorded the same fact conflicts on `business_key`.
Its outcome is `duplicate` (with `duplicate_of_path = reconciliation` on the receipt), and the PMS
gets `200`. Reconciliation inserts with `ON CONFLICT DO NOTHING` on both keys, so it never adds
a fact a webhook already recorded.

A reconciled fact stores the `/v1` Payment snapshot as its payload (the same shape as a
webhook's `data.object`), `occurred_at = received_at` for a payment and `reversal.reversed_at`
for a reversal, and `arrival_path = reconciliation`.

**Rationale**: FR-016 and US3 AC3. Two keys keep the PMS event ID as the documented dedup key
(webhooks.md) while also covering facts that came by the other path.

**Alternatives**: deduplicating only on business keys (loses the documented event-ID rule for
lease events); updating a reconciled row when its webhook arrives (rejected: raw events are
immutable, Constitution I).

## R5. Reconciliation: a resumable walk of `/v1/payments`

**Decision**: per connection, every `RECONCILE_INTERVAL_S` (default 900):

- **Window**: `updated_since = watermark − RECONCILE_OVERLAP_S` (default 3600). A new
  connection has no watermark, so its first run is a **full backfill**: about 12 months, a few
  hundred payments for a seeded operator, or a handful of pages at `limit=200`.
- **Walk**: `GET /v1/payments?updated_since=…&limit=200`, following `next_cursor`. After each
  page commits, the cursor is saved on the connection (`reconcile_cursor`), so an interrupted
  run resumes mid-walk (FR-018). The mock's keyset pagination is stable while new rows arrive
  (001 R9).
- **Per payment**: insert `payment.created:<id>`, and also `payment.reversed:<id>` when
  `status = reversed`, both with `ON CONFLICT DO NOTHING`.
- **End**: the new watermark is the run's **start** time (RentSync's clock, kept in sync by
  chrony, 002 FR-012), the cursor is cleared, and `next_reconcile_at = now + interval`. The
  overlap absorbs clock skew and late-committed rows.
- **Failure**: the run records its error, keeps the cursor, and retries after an exponential
  backoff (30 s doubling to the interval, with jitter). Health shows the failure (US4 AC3).

Operators can trigger a run now (FR-020); that sets `next_reconcile_at = now()`.

**Rationale**: the spec covers payments and reversals. Lease events lost on every delivery
attempt are rare (the duplicate chaos and the mock's 8 retries) and can be replayed through the
mock's admin API. Extending reconciliation to leases belongs with the ledger, which needs it.

## R6. Calling the PMS politely: a shared bucket plus backoff

**Decision**: every PMS API call (not the token endpoint, which the PMS exempts) first takes a
token from a **Redis token bucket keyed on the PMS client**, because the PMS limits the
*client*, across all its connections (001 FR-021). The bucket's capacity and refill are
configuration, defaulting to 50 a minute against the mock's 60, so normal runs never see a
`429`. The Lua script is the mock's, copied (R1).

When a `429` does arrive anyway:

- RentSync stores `pms:<client>:blocked_until = now + Retry-After` in Redis (`SET … PXAT`,
  keeping the later value), so **every** instance waits, not only the one that was refused;
- the call is retried after at least `Retry-After`, then with exponential backoff and full
  jitter (base 1 s, cap 60 s) on further `429`s, `5xx` and timeouts;
- after 6 failed attempts the run fails and is retried by R5's backoff.

If Redis is unavailable, reconciliation waits rather than calling without a bucket (fail
closed, like 001 R8).

**Rationale**: Constitution IV and X: rate state is shared, never in process memory. SC-007
allows only the requests already in flight to exceed the limit.

## R7. Connecting: authorization code with PKCE and server-side state

**Decision**:

- `POST /connections` (signed-in, CSRF-checked) creates a `connection_attempts` row: a random
  `state` (stored as a SHA-256 digest), a PKCE `code_verifier` (encrypted, R8), the operator,
  and a 10-minute expiry. It then redirects to the PMS's `/oauth/authorize` with
  `code_challenge_method=S256`.
- `GET /connections/callback?code&state` looks up the attempt by state digest, checks it
  belongs to the signed-in operator, is unexpired and unused, and marks it used with a
  conditional `UPDATE … WHERE used_at IS NULL` (single use). It exchanges the code with the
  verifier and the client credentials. `error=access_denied` records the denial on the attempt
  and shows it (US1 AC2); nothing else is stored.
- **Which PMS operator?** The token response does not say. This feature **extends the mock
  PMS**: `/oauth/token` responses gain `operator_id` and `operator_name`. That is backward
  compatible (a new field), and real platforms commonly return the account in the token
  response or a `whoami` call. Feature 001's contract and specs are updated in the same change.
- **Reconnecting** the same PMS operator (FR-008) updates the existing `pms_connections` row
  (new credentials, status `active`, reauth cleared); its history stays linked. A PMS operator
  already connected to a **different** RentSync operator is refused with a clear message.

**Rationale**: PKCE and single-use state stop forged and replayed callbacks (FR-002). The mock
already supports S256 (001 openapi).

## R8. Encrypting PMS credentials at rest

**Decision**: AES-256-GCM from Ruby's `openssl` stdlib. Each encrypted value is stored as
`v1:<key_id>:<nonce>:<ciphertext+tag>` (base64 parts). The 12-byte nonce is random per
encryption. The **associated data** is `"<table>.<column>:<row id>"`, so a ciphertext copied
to another row or column fails to decrypt. Keys come from `RENTSYNC_ENCRYPTION_KEYS`
(`key_id=base64key,…`; the first one encrypts, all decrypt), rendered from SSM by
`rentsync-render-env`. Re-encryption under a new key happens lazily, on the next write.

Encrypted: the access token, refresh token, PKCE verifier, and the PMS client's secret and
signing secret (R9).

**Rationale**: Constitution VII requires encryption for tokens RentSync must present again. The
stdlib's OpenSSL binding provides the primitive, so nothing cryptographic is written locally
(VIII) and no gem is needed. GCM authenticates as well as encrypts.

**Alternatives**: `lockbox` or `rbnacl` (rejected: a dependency for a few lines over stdlib
OpenSSL); Postgres `pgcrypto` (rejected: the key would travel in SQL and could land in logs).

## R9. Registering RentSync with the PMS

**Decision**: `bin/setup --deploy` (and `bin/setup` locally) runs `PmsRegistration.ensure!`. It
checks that the stored client still exists (in the mock's `GET /admin/clients` list), and if not,
registers one through `POST /admin/clients` with:

- name `rentsync-<deployment_id>`;
- redirect URI `<APP_PUBLIC_URL>/connections/callback`;
- subscriber URL `<WEBHOOK_SUBSCRIBER_URL>`.

The four URL settings are in R13.

The returned client secret and signing secret are stored encrypted in `pms_clients`. If the
client had vanished (a mock `/admin/reset` clears clients), every connection under the old one
is marked `needs_reauth`.

This uses the mock's **admin** token (`MOCK_PMS_ADMIN_TOKEN`, the same SSM value the mock uses).
That shortcut exists only because the PMS is our own mock. With a real platform, the client
credentials would arrive out of band and be supplied as configuration; the `pms_clients` row
also accepts them that way (`bin/pms_client --set`). The ADR records this.

**Rationale**: zero manual steps per deployment, and each deployment gets its own client and
signing secret (FR-025).

## R10. Health figures come from durable rows, not counters

**Decision**: every webhook delivery writes one `webhook_receipts` row: arrival time, PMS
delivery ID and attempt, event ID and type where readable, connection where known, outcome
(`recorded`, `duplicate`, or `rejected`), reason code, body length and SHA-256, and correlation
ID. Health figures are aggregate queries over `raw_events`, `webhook_receipts` and
`reconciliation_runs`, scoped to the operator, with indexes on `(connection_id, received_at)`.

- *Events received* = raw events recorded (both paths, split by path).
- *Duplicates ignored* and *events rejected by reason* = receipts by outcome and reason.
- *Last successful sync* = the later of the newest recorded webhook event and the newest
  successful reconciliation.

Receipts are kept for 90 days (spec assumption); figures from receipts say "last 90 days".
Raw events are kept forever.

**Rationale**: FR-022 asks for figures correct across instances and restarts. Rows in Postgres
are exact and durable with no extra machinery, and they double as the audit trail that
FR-012 needs. At demo volume (a few thousand rows a month) the queries are trivial. The
Prometheus metrics in R12 are for telemetry, not for the health view.

**Alternatives**: Redis counters (lossy on Redis restart, against FR-022); counter columns
updated in place (a hot row, and no per-delivery audit).

## R11. Operator accounts and sessions

**Decision**:

- `operators` rows are **seeded**, one per mock PMS operator, with synthetic emails and a
  development password from `.env`. On hosts the seed password comes from SSM
  (`operator_seed_password`). Passwords are bcrypt hashes (`bcrypt`, already used by the mock).
- Signing in creates a `sessions` row. The cookie holds a random 32-byte token; the table
  holds only its SHA-256 (Constitution VII). Cookies are `HttpOnly`, `Secure` (except on
  `localhost`), `SameSite=Lax` (`Lax` lets the OAuth callback, a top-level GET from the PMS,
  carry the session). Sessions expire after 12 hours idle and 7 days absolute.
- Every state-changing form carries a per-session CSRF token, checked in constant time.
- Sign-in attempts are rate limited per email and per IP with the same Redis bucket (5 per
  minute), returning the same generic error for unknown email and wrong password.
- Every query for connections, events, receipts and runs is scoped by `operator_id` from the
  session, on the server (FR-023).

**Rationale**: the user chose RentSync accounts (spec, Clarifications). These pieces are small
enough to write and test locally; bcrypt is the one security-sensitive primitive, and it is a
dependency.

## R12. Pages are server-rendered for now; Next.js waits for the dashboard

**Decision**: this feature's UI is three server-rendered ERB pages served by the API: sign-in,
connections (connect, reconnect, disconnect, reconcile now), and connection health (figures and
the latest 50 rejections). They are plain HTML with a small stylesheet and no JavaScript. The
same data is also available as JSON at `/v1/connections` and `/v1/connections/{id}/health`, which
the dashboard will consume.

**Rationale**: the kickoff puts Next.js in `/web`. For three forms and two tables, Next.js would
add a Node runtime, an npm dependency tree, a third container on a 1 GiB host (R14), and a
second auth surface (cookies across two services) before there is anything to justify it. The
operator dashboard feature introduces `/web` and consumes the JSON endpoints, and these pages
can then redirect there. The mock PMS's approval page already uses ERB, so no dependency is
added.

**Alternatives**: Next.js now (rejected as above); a JSON API only with no pages (rejected:
operators could not connect without a browser flow, US1).

## R13. Where RentSync lives on each host

**Decision**:

- **Hostnames**: a new public hostname per deployment: `app-staging.rentsync.org` for
  `dev-staging` and `app.rentsync.org` for `prod-us`, pointing at the same Elastic IP. Caddy
  gets a second site block that proxies it to `api:4002`, with the same `/metrics` 404. Caddy
  obtains its certificate itself. The A records are added by hand (DNS is manual, 002), and
  each workspace gets an `app_hostname` variable.
- **Webhooks travel the public path**: the PMS's subscriber URL is
  `https://<app hostname>/webhooks/pms`, so deliveries go out through TLS and Caddy like a real
  vendor's, even though both services share a host.
- **Database**: a second database on the same Postgres container, `rentsync_<deployment>`
  (`rentsync_prod_us`), created by `bin/setup`. It uses the same Postgres credentials as the mock,
  which is acceptable for the demo; production-differences.md notes that a real deployment gives
  each service its own role.
- **Redis**: the same Redis, under the key prefix `rentsync:` (the mock's keys are unprefixed
  and differently named), database 1.
- **Secrets**: three new SSM parameters per deployment, written by Terraform's write-only
  pattern (002 R11, ADR-0007): `rentsync/encryption_keys`, `rentsync/operator_seed_password`,
  and `rentsync/session_secret` (for the CSRF HMAC). `rentsync-render-env` requires them.

- **Two URLs per side.** A browser and a container reach the services by different names, so
  each side has a public URL and an internal one:

  | Setting | Used by | Hosts | Local and CI |
  |---|---|---|---|
  | `PMS_PUBLIC_URL` | the browser, for `/oauth/authorize` | `https://<SITE_HOSTNAME>` | `http://localhost:4001` |
  | `PMS_API_URL` | the API, for `/oauth/token`, `/v1`, `/admin` | `https://<SITE_HOSTNAME>` | `http://mock_pms:4001` |
  | `APP_PUBLIC_URL` | redirect URI, cookies, links | `https://<APP_HOSTNAME>` | `http://localhost:4002` |
  | `WEBHOOK_SUBSCRIBER_URL` | registered with the PMS, called by its worker | `https://<APP_HOSTNAME>/webhooks/pms` | `http://api:4002/webhooks/pms` |

  `bin/connect_operator` (R17) drives the browser side, so it runs on the developer machine or
  CI runner, where the published ports resolve, not inside a container.

**Rationale**: separate hostnames keep both services' URL spaces intact (the mock owns `/`,
`/oauth`, `/v1`, `/admin`) and make the demo legible: one name for the vendor, one for the
product.

**Alternatives**: path-based routing under the PMS hostname (rejected: path collisions with
`/v1` and `/admin`, and it blurs the vendor/product boundary); delivering webhooks over the
Compose network (rejected: skips TLS and Caddy, which a real vendor would traverse).

## R14. Memory on t4g.micro hosts

**Decision**: deploy to the current t4g.micro hosts (1 GiB, with the 002 swap file), and
**measure** before deciding to size up.

Rough budget per environment host, from 001 and 002 experience:

| Container | Typical RSS |
|---|---|
| Caddy | ~30 MB |
| Postgres | ~60–100 MB |
| Redis | ~10 MB |
| mock_pms web + worker | ~2 × 90 MB |
| otel-collector | ~100–150 MB (GOMEMLIMIT 204 MiB) |
| **new** api web + worker | ~2 × 90 MB |
| **Total** | **~560–650 MB** of ~900 MB usable |

To keep the new processes lean: Puma in single mode with 3 threads, `MALLOC_ARENA_MAX=2`, and no
eager loading of unused code. Each new container gets a Compose `mem_limit` (256 MB web,
192 MB worker), so a leak kills that container, not the host.

**Gate**: quickstart §5 deploys to `dev-staging` first and records `free -m` and
`docker stats` after a month-end burst. If available memory stays under 150 MB, or swap use
keeps growing, both environment workspaces set `instance_type = "t4g.small"` (runbook §Changing
a host's instance type; about +$12.26 a month each). The decision and the numbers go in the
build log.

## R15. Releasing two images together

**Decision**: a second ECR repository, `rentsync/api`, in the shared workspace, with the same
immutable tags and lifecycle policy as the mock's. `release.yml` builds both images, tagged with
the same commit SHA. A release is **one unit**: `rentsync-deploy` pulls both, migrates both,
restarts both, and checks both `/healthz` endpoints. A failed check rolls both back to the
previous tag (002 R9), and `image_tag` in SSM stays a single value. The IAM policies for the
GitHub release role (push) and the host role (pull) gain the new repository.

Migrations stay **expand-only** (002 research R9), so rolling back the image never meets a
schema it can't read.

**Rationale**: one tag per release keeps rollback simple and matches the existing pipeline.

## R16. Telemetry

**Decision**:

- The Collector already tails every container's JSON stdout. Its prometheus receiver gains
  scrape jobs for `api:4002/metrics` and `api_worker:4003/metrics` (the worker serves a
  minimal metrics endpoint, as the mock's worker does).
- Service names: `rentsync-api-web` and `rentsync-api-worker`.
- New metrics: `rentsync_webhook_receipts_total{outcome,reason}`,
  `rentsync_raw_events_total{arrival_path,type}`, `rentsync_token_renewals_total{result}`,
  `rentsync_reconciliation_runs_total{result}`, `rentsync_pms_requests_total{status}`,
  `rentsync_pms_rate_limit_waits_seconds_total`, and the usual HTTP request metrics. Labels never
  carry tenant data, tokens or operator emails (FR-024).
- **Correlation IDs**: a webhook's `X-Correlation-Id` (set by the PMS, 001 R10) is kept and
  stored on the raw event; without one, RentSync generates one. Reconciliation runs get their
  own correlation ID, stored on every fact they record. The ledger will carry it forward
  (Constitution VI).

## R17. Testing

**Decision**:

- **Test-first units** (Constitution III): signature verification against 001's frozen vector
  (`mock_pms/spec/fixtures/signature_vector.json`, copied), timestamp window, envelope
  validation, the dedup decision (recorded, duplicate, conflicting, cross-path), the AES-GCM
  envelope (including the AAD swap failure), PKCE and state single use, the renewal lease, the
  backoff schedule, the `Retry-After` handling, and the reconciliation window and cursor.
- **Request specs** (Rack::Test, real Postgres and Redis): sign-in, CSRF, operator scoping, the
  connect callback (with a stubbed PMS token endpoint), and every webhook outcome.
- **End-to-end** (Constitution III): a signed HTTP request through the full Rack stack to a
  persisted raw event and receipt. The constitution's "to the persisted ledger effect" ends at
  the raw event until the ledger exists (spec, Assumptions).
- **Live integration** in CI: a new `ingestion-e2e` job starts the mock and the API in Compose,
  connects a seeded operator through the real OAuth flow (`bin/connect_operator`, a headless
  driver of the approval form), runs the month-end burst **with every chaos setting on**, runs
  one reconciliation, and compares RentSync's raw events to `GET /admin/events` (SC-003). It
  reuses the CI telemetry-smoke pattern.
- The PMS HTTP client is tested against a small fake PMS (a Rack app served by Puma, as 001's
  test receiver is), with scripted `429`s, `5xx` and `invalid_grant`.

## R18. Dependencies

No new gems beyond the mock's set. The API's Gemfile is the same six runtime gems:

| Gem | Purpose | Justification |
|---|---|---|
| `grape` | HTTP API | The project-standard API framework (kickoff §3) |
| `puma` | Rack server | Standard threaded server |
| `sequel` | Database access and migrations | Project-standard ORM |
| `pg` | Postgres driver | Required by Sequel for Postgres |
| `bcrypt` | Operator password hashing | Security-sensitive primitive; no stdlib equivalent |
| `redis` | Rate-limit bucket, sign-in throttle, metric totals | Official client; `EVALSHA` and `MULTI` for atomic shared state (Constitution X) |

Dev: `rspec`, `rack-test`, `rubocop`, as in the mock. Everything else is stdlib: `openssl`
(HMAC, AES-GCM, digests), `net/http`, `json`, `erb`, `securerandom`, `uri`.
