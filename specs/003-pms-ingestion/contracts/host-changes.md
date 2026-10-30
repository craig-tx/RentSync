# Contract Change: Environment Hosts Run RentSync

Extends feature 002's [host-interface.md](../../002-aws-deployment/contracts/host-interface.md)
and [workspace-variables.md](../../002-aws-deployment/contracts/workspace-variables.md).
Decisions: research R13–R16.

## New workspace variables (`infra/terraform/environment`)

| Variable | Sensitive | Example | Rules |
|---|---|---|---|
| `app_hostname` | no | `app-staging.rentsync.org` | RentSync's public hostname; the A record is added by hand to the same Elastic IP. No default |
| `rentsync_encryption_keys` | yes, write-only | `k1=<base64 32 bytes>` | `key_id=base64key[,…]`, key IDs `[A-Za-z0-9_-]{1,32}` as `Crypto::Box` accepts; first encrypts; not the `.env.example` key. Generate: `printf 'k1=%s' "$(openssl rand -base64 32)"` |
| `rentsync_encryption_keys_version` | no | `1` | bump to write a change (002 R11 pattern) |
| `rentsync_operator_seed_password` | yes, write-only | | ≥ 16 chars, not the `.env.example` value; the seeded operators' sign-in password, set only when an operator is first created |
| `rentsync_operator_seed_password_version` | no | `1` | |
| `rentsync_session_secret` | yes, write-only | | ≥ 32 URL-safe chars, not the `.env.example` value; keys the CSRF HMAC |
| `rentsync_session_secret_version` | no | `1` | |

They become SSM SecureString parameters under the deployment's existing path, in a
`rentsync/` sub-path: `rentsync/encryption_keys`, `rentsync/operator_seed_password`,
`rentsync/session_secret`. `rentsync-render-env` requires all three on environment hosts. The
host module depends on them, so a replaced host never boots before they exist.

## Rendered environment additions

| Key | Source |
|---|---|
| `APP_HOSTNAME` | host.env, from `app_hostname` |
| `RENTSYNC_DATABASE_URL` | `postgres://postgres:<postgres_password>@postgres:5432/rentsync_<deployment_id_with_underscores>` |
| `RENTSYNC_REDIS_URL` | `redis://redis:6379/1` |
| `RENTSYNC_ENCRYPTION_KEYS`, `RENTSYNC_OPERATOR_SEED_PASSWORD`, `RENTSYNC_SESSION_SECRET` | SSM |
| `MOCK_PMS_ADMIN_TOKEN` | the existing `admin_token` (research R9) |
| `PMS_PUBLIC_URL`, `PMS_API_URL` | both `https://<SITE_HOSTNAME>` (research R13) |
| `APP_PUBLIC_URL` | `https://<APP_HOSTNAME>` |
| `WEBHOOK_SUBSCRIBER_URL` | `https://<APP_HOSTNAME>/webhooks/pms` |
| `API_IMAGE` | set by `rentsync-deploy`, like `MOCK_PMS_IMAGE` |
| `API_ECR_REPOSITORY_URL` | host.env: the shared output `api_ecr_repository_url`, or, until that exists, the mock's URL with `/mock_pms` → `/api` |

## Compose (`infra/host/compose.env.yaml`)

New services `api` (port 4002, `mem_limit: 256m`) and `api_worker` (`mem_limit: 192m`, metrics on
4003), from `${API_IMAGE}`, with `MALLOC_ARENA_MAX=2`, Puma single mode, 3 threads. Both get
the keys `Settings.validate!` requires; only `api` gets `MOCK_PMS_ADMIN_TOKEN`. Service names
`rentsync-api-web` and `rentsync-api-worker` (research R16). Both are in the Compose profile
`api`, which `rentsync-deploy` enables only for a release that carries an API image.

## Caddy (`infra/host/Caddyfile.env`)

A second site block for `{$APP_HOSTNAME}`: `respond /metrics* 404`, `reverse_proxy api:4002`.

## Deploy (`rentsync-deploy`)

- The ref is `<sha>@sha256:<mock digest>+sha256:<api digest>`, recorded whole in `image_tag`.
  Both images are pinned by digest. A ref without `+…` (every release before this feature, or
  a bare `<sha>`) runs the mock alone and stops the API, so rollbacks and reloads to such a ref,
  and the first boot of a replaced host, keep working. An API digest on a host without
  `API_ECR_REPOSITORY_URL` is refused (exit 64).
- Pulls both, then runs the mock's `bin/setup --deploy` and starts it, then the API's
  (migrate; seed if empty; `Pms::Registration.ensure!`, which reaches the mock through its
  public URL, so the mock must be serving first).
- Healthy only when both services' `/healthz` report the new version over the Compose network
  (the API's `/healthz` needs a live worker heartbeat, so it covers `api_worker`); otherwise
  both roll back to the previous ref. `deploy-to.yml`'s external check then verifies
  both public URLs, so the `app-*` A records **must exist before the first release that
  includes the API** (quickstart §5 order), or that release goes red.

## Release and registry

- A second ECR repository `<deployment_id>/api` (`shared-us/api`, shared workspace), same tag
  immutability and lifecycle as the mock's; outputs `api_ecr_repository_url` and `_arn`.
- The GitHub build role may push to it (`docs/deploy/iam/github-build-policy.json`, applied by
  the operator with `bootstrap-iam.sh`); host roles may pull from it.
- `release.yml` and `deploy.yml` build and push both images with the commit SHA tag. The API
  image is built only once the repository variable `API_ECR_REPOSITORY_URL` is set
  (`bootstrap-github.sh --api-ecr-repository-url`); until then a release ships the mock alone.
- GitHub Environments gain `APP_URL`, which `deploy-to.yml` checks when a release carries the
  API.
- Order of the one-time switch-on: runbook §Releasing RentSync's API.

## Collector (`infra/otel/collector.yaml`)

A scrape job `rentsync-api-web` for `api:4002`, same interval variable. Not `api_worker:4003`:
every instance renders the same Redis totals, so a second target would store every series
twice (the mock's worker isn't scraped either). The log filter keeps lines whose
`service.name` starts with `rentsync-` as well as the mock's.
