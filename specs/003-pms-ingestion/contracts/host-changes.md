# Contract Change: Environment Hosts Run RentSync

Extends feature 002's [host-interface.md](../../002-aws-deployment/contracts/host-interface.md)
and [workspace-variables.md](../../002-aws-deployment/contracts/workspace-variables.md).
Decisions: research R13–R16.

## New workspace variables (`infra/terraform/environment`)

| Variable | Sensitive | Example | Rules |
|---|---|---|---|
| `app_hostname` | no | `app-staging.rentsync.org` | RentSync's public hostname; the A record is added by hand to the same Elastic IP |
| `rentsync_encryption_keys` | yes, write-only | `k1=<base64 32 bytes>` | `key_id=base64key[,…]`; first encrypts. Generate: `printf 'k1=%s' "$(openssl rand -base64 32)"` |
| `rentsync_encryption_keys_version` | no | `1` | bump to write a change (002 R11 pattern) |
| `rentsync_operator_seed_password` | yes, write-only | | ≥ 16 chars; the seeded operators' sign-in password |
| `rentsync_operator_seed_password_version` | no | `1` | |
| `rentsync_session_secret` | yes, write-only | | ≥ 32 URL-safe chars; keys the CSRF HMAC |
| `rentsync_session_secret_version` | no | `1` | |

They become SSM SecureString parameters under the deployment's existing path, in a
`rentsync/` sub-path: `rentsync/encryption_keys`, `rentsync/operator_seed_password`,
`rentsync/session_secret`. `rentsync-render-env` requires all three on environment hosts.

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

## Compose (`infra/host/compose.env.yaml`)

New services `api` (port 4002, `mem_limit: 256m`) and `api_worker` (`mem_limit: 192m`, metrics on
4003), from `${API_IMAGE}`, each receiving only the variables it needs, with
`MALLOC_ARENA_MAX=2`, Puma single mode, 3 threads.

## Caddy (`infra/host/Caddyfile.env`)

A second site block for `{$APP_HOSTNAME}`: `respond /metrics* 404`, `reverse_proxy api:4002`.

## Deploy (`rentsync-deploy`)

- Pulls `MOCK_PMS_IMAGE` and `API_IMAGE` at the same tag.
- Runs `bin/setup --deploy` for both (migrate; seed if empty; for the API, also
  `PmsRegistration.ensure!`).
- Healthy only when both services' `/healthz` report the new version over the Compose network;
  otherwise both roll back to the previous tag. `deploy-to.yml`'s external check then verifies
  both public URLs, so the `app-*` A records **must exist before the first release that
  includes the API** (quickstart §5 order), or that release goes red.

## Release and registry

- A second ECR repository `rentsync/api` (shared workspace), same tag immutability and
  lifecycle as the mock's.
- The GitHub release role may push to it; host roles may pull from it.
- `release.yml` builds and pushes both images with the commit SHA tag.
- GitHub Environments gain `APP_URL` for `deploy-to.yml`'s external check.

## Collector (`infra/otel/collector.yaml`)

Scrape jobs for `api:4002` and `api_worker:4003`, same interval variable.
