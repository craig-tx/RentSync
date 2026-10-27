# Contract: host interface (deploy script, health, ports)

## `rentsync-deploy` (environment hosts, `/usr/local/bin/rentsync-deploy`)

Runs as root, invoked through SSM Run Command (`AWS-RunShellScript`) or by `rentsync.service`
at boot.

```text
rentsync-deploy <ref>          deploy <sha>@sha256:<digest> (what releases always pass), or a
                               bare 40-char <sha>. The host pulls <ecr>:<ref>, so a pinned
                               digest makes Docker refuse any other image under that tag.
                               The whole <ref> is recorded in image_tag; /healthz.version is
                               checked against the <sha> part
rentsync-deploy --rollback     deploy previous_image_tag
rentsync-deploy --reload       re-render secrets and (re)start the current image_tag
                               (boot, secret rotation); if image_tag is "none", starts only Caddy
                               (certificates can issue before the first deploy)
                               and prints "no image deployed yet"
```

**Behavior**:

1. Takes `flock /run/rentsync/deploy.lock`. A second invocation waits up to 10 minutes, then
   exits 75 (`EX_TEMPFAIL`).
2. Renders `/run/rentsync/env` (0600) from SSM. The file contains:
   - `DEPLOYMENT_ID` (e.g. `prod-us`) and `DEPLOYMENT_ENVIRONMENT`;
   - `COMPOSE_PROJECT_NAME=rentsync-<deployment_id>`;
   - `DATABASE_URL` (built from `postgres_password`, database `mock_pms_<deployment_id with _>`);
   - `REDIS_URL`;
   - `ADMIN_TOKEN`;
   - `OPENOBSERVE_OTLP_ENDPOINT`, `OPENOBSERVE_USER`, `OPENOBSERVE_PASSWORD`;
   - `MOCK_PMS_IMAGE`.
3. If `<image_tag>` equals the running tag and `/healthz` is already ok with that version, it
   prints `already running <tag>` and exits 0.
4. Logs in to ECR (`aws ecr get-login-password`) and runs `docker compose pull`.
5. Runs `docker compose run --rm mock_pms bundle exec bin/setup --deploy` (migrate, and seed
   only if empty).
6. Runs `docker compose up -d --remove-orphans`.
7. Polls `docker compose exec -T mock_pms curl -fsS localhost:4001/healthz` every 3 s for up to
   120 s, until `status == "ok"` and `version == <image_tag>`.
8. **Success**: puts `previous_image_tag` ← the old tag and `image_tag` ← the new tag, prints
   `deployed <tag>`, and exits 0.
9. **Failure**: re-runs steps 4–7 with the old tag, prints `rolled back to <old>`, and exits 1.
   If the old tag also fails, it prints `FAILED: environment unhealthy` and exits 2.

Output is plain lines for the workflow log. No secret value is ever echoed, so `set -x` is
forbidden in this script.

## `/healthz` (mock PMS, changed in this feature)

```json
GET /healthz        200 {"status":"ok","db":"ok","redis":"ok","worker_heartbeat_age_s":3,"version":"<sha>","deployment_id":"prod-us",
                         "time":"2026-10-27T12:00:05Z","started_at":"2026-10-27T11:58:40Z",
                         "time_ct":"2026-10-27 07:00:05 CDT","started_at_ct":"2026-10-27 06:58:40 CDT"}
                    503 {"status":"degraded",...,"version":"<sha>","deployment_id":"prod-us","time":...}
GET /healthz/live   200 {"status":"ok","version":"<sha>","deployment_id":"prod-us","time":...}
```

`version` is `SERVICE_VERSION`: the full git commit SHA the image was built from (the build's
`GIT_SHA`), or `dev` locally. `deployment_id` is `DEPLOYMENT_ID`, so the release check also proves
it reached the intended deployment. `time` is the server's current time and `started_at` is when
the web process started (both UTC, ISO 8601), so a reader can tell the answer is fresh and when
the last deploy or restart happened. `time_ct` and `started_at_ct` repeat them in US Central time
for reading (`MockPms::CentralTime`). Every endpoint returns all six. These are additions only.
Existing fields and status codes are unchanged (001 `contracts/openapi.yaml` has them all).

## `bin/setup --deploy` (mock PMS, new flag)

- Requires `DATABASE_URL`. It does **not** read `TEST_DATABASE_URL`.
- Creates the database if it is missing, and runs migrations.
- Seeds with `(SEED, SEED_ANCHOR_DATE)` only if the `operators` table is empty.
- Exits 0 and prints `setup complete (deploy; seeded=<true|false>)`. Running it twice gives the
  same end state.

## Public surface per host

| Host | Port | Path | Result |
|---|---|---|---|
| environment | 80 | any | `308` to `https://<hostname>{uri}` |
| environment | 443 | `/metrics` | `404` (internal-only; the Collector scrapes it over the Compose network) |
| environment | 443 | everything else | proxied to `mock_pms:4001`, with headers passed through |
| telemetry | 80 | any | `308` to HTTPS |
| telemetry | 443 | any | proxied to `openobserve:5080`; OpenObserve's own sign-in page |
| telemetry | 5080 | `/api/default/v1/{logs,metrics}` | OTLP/HTTP; reachable only from each environment's subnet, over its peering connection (ADR-0008) |

## SSM targeting

Deploys target `Key=tag:DeploymentId,Values=<deployment_id>` and
`Key=tag:rentsync:deployable,Values=true,protected`. Exactly one instance carries each
DeploymentId. Non-production hosts are tagged `rentsync:deployable = true`, and only
`rentsync-github-actions` may run `AWS-RunShellScript` on them. A new deployment is therefore
deployable with no IAM change. Production hosts are tagged `protected`, and only
`rentsync-github-actions-prod` may run commands on them. That role is trusted solely for the
`prod-us` GitHub Environment (contracts/bootstrap-iam.md).
