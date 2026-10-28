# Quickstart: Validate PMS Connection and Webhook Ingestion

Runnable checks that prove feature 003 end to end. Contracts:
[openapi.yaml](contracts/openapi.yaml), [webhook-receiver.md](contracts/webhook-receiver.md).
Commands are bash (Git Bash or WSL on Windows, Terminal on macOS), per the constitution's
cross-platform rule.

## Prerequisites

- Docker Desktop, and the repo's `.env` copied from `.env.example`.
- For §5–§6: the 002 deployments running, and A records for `app-staging.rentsync.org` and
  `app.rentsync.org` pointing at their hosts' Elastic IPs.

## 1. Local stack

```bash
docker compose up -d --build --wait
docker compose exec -T mock_pms bundle exec bin/setup
docker compose exec -T api bundle exec bin/setup      # migrate, seed operators, register with the PMS
curl -s localhost:4002/healthz
```

**Expected**: `status: ok`, `worker_heartbeat_age_s` under 10. `bin/setup` prints the PMS
client ID (never its secrets) and the seeded operator emails.

## 2. Connect (US1, SC-001, SC-002)

1. Open `http://localhost:4002/sign-in`, sign in as the first seeded operator (password from
   `.env`), choose **Connect PMS**, approve on the mock's page.
   **Expected**: back on `/connections`, status `active`, the PMS operator's name shown, all in
   under 2 minutes.
2. Repeat but choose **Deny**. **Expected**: "access was denied", no new connection.
3. Headless equivalent, used by CI: `docker compose exec -T api bundle exec bin/connect_operator --operator 1`.
4. Wait 6 minutes (past the 5-minute access token), then **Reconcile now**.
   **Expected**: the run succeeds; logs show one `token_renewed` event and no 401 from the PMS.
5. Revoke the grant (`POST /admin/grants/{id}/revoke` on the mock), then **Reconcile now**.
   **Expected**: status `needs_reauth`, a reconnect button; reconnecting restores `active` with
   the same history.
6. Sign in as the second operator. **Expected**: the first operator's connection is not listed,
   and its health URL returns 404.

## 3. Exactly once under chaos (US2, SC-003, SC-005)

```bash
set -a; . ./.env; set +a
curl -fsS -X PUT localhost:4001/admin/chaos -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"duplicate_rate":0.3,"out_of_order_rate":0.3,"delay_rate":0.2,"delay_min_s":1,"delay_max_s":5,"malformed_rate":0.1,"server_error_rate":0.1,"seed":7}'
curl -fsS -X POST localhost:4001/admin/scenarios/month_end_burst -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' -d '{}'
docker compose exec -T api bundle exec bin/compare_with_pms --wait 180 --reconcile
```

`bin/compare_with_pms` lists the PMS's true events (`GET /admin/events`) for connected
operators, triggers one reconciliation, then lists RentSync's raw events (`/admin/raw_events`).

**Expected**:

- 0 missing and 0 duplicated facts; the counts match per type;
- every malformed delivery appears under `malformed_body` on the health page;
- the health page's received, duplicate and rejected figures equal `/admin/receipts`.

Also:

- a delivery signed with a wrong secret (`bin/send_test_webhook --bad-signature`) gets 401 and
  shows as `bad_signature`;
- one sent with `--timestamp-offset -600` shows as `stale_timestamp`.

Reset chaos to 0 afterwards.

## 4. Reconciliation catches lost webhooks (US3, SC-004, SC-007)

1. `docker compose stop api` so deliveries fail; set the mock's `MAX_ATTEMPTS=1` for this run,
   or wait for exhaustion. Run `nsf_wave` and `month_end_burst`.
2. `docker compose start api`, then **Reconcile now** (or `bin/compare_with_pms --reconcile`).
   **Expected**: every missing payment and reversal is recorded with `arrival_path =
   reconciliation`; then an admin replay of those events on the mock (`POST /admin/replays`)
   yields `duplicate` receipts with `duplicate_of_path = reconciliation`, and no new facts.
3. Rate limit: set the mock client's limit to 10 a minute (`PATCH /admin/clients/{id}`) and
   reconcile a fresh connection (full backfill).
   **Expected**: the run finishes; `rentsync_pms_rate_limit_waits_seconds_total` rises; the mock's
   delivery and request logs show no more than the in-flight requests beyond the limit.
4. Kill the worker mid-backfill (`docker compose kill api_worker`), start it again.
   **Expected**: the interrupted run shows `failed / interrupted`; the next run resumes from the
   saved cursor; the final raw events equal a clean run's.
5. Scale out: `docker compose up -d --scale api_worker=2`, trigger reconcile.
   **Expected**: one run per connection at a time.

## 5. Deployed (FR-025)

1. Operator: set the new workspace variables (contracts/host-changes.md) and apply
   `rentsync-shared-us` (the ECR repository and IAM), then `rentsync-dev-staging`, then
   `rentsync-prod-us`. Add the two A records.
2. Merge to `main`; the release deploys both images to staging, then prod after approval.
3. Check:

   ```bash
   curl -s https://app-staging.rentsync.org/healthz        # ok, version = merge SHA
   curl -sI http://app-staging.rentsync.org/ | head -1     # 308
   curl -s -o /dev/null -w '%{http_code}\n' https://app-staging.rentsync.org/metrics   # 404
   ```

4. Repeat §2 (steps 1, 4) and §3 against staging, using the staging hostnames, then reset chaos.
5. **Memory gate (research R14)**: on each environment host, after §3, record `free -m` and
   `docker stats --no-stream`. If available memory is under 150 MB, or swap use keeps growing,
   set `instance_type = "t4g.small"` for both environment workspaces. Record the numbers and
   the decision in the build log.

## 6. Telemetry (FR-024)

In OpenObserve, filter `service.name = rentsync-api-web` and `deployment.id = dev-staging`:

- the receipts, renewals and reconciliation metrics are present;
- searching a webhook's `correlation_id` finds the mock's send log and RentSync's receipt log;
- searching logs for a seeded tenant's surname, an access token prefix, or the signing secret
  finds nothing.

## 7. Automated suite

```bash
docker compose run --rm api bundle exec rspec
docker compose run --rm api bundle exec rubocop
```

CI runs these plus the `ingestion-e2e` job (research R17), which automates §2 step 3 and §3.
