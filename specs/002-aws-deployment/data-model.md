# Data Model: AWS Deployment of the Mock PMS

**Feature**: `002-aws-deployment` | **Date**: 2026-10-21

This feature adds no database tables. Its "data model" is the set of infrastructure entities,
their identifiers, and the runtime state that lives in SSM and on the hosts. Workspace inputs and
outputs are listed in [contracts/workspace-variables.md](contracts/workspace-variables.md).

## Deployment (constitution Principle VI, research R17)

A deployment is one long-lived stack instance, identified by its **DeploymentId**. It is not a
release; the running build is `service.version`. Every name it owns is derived from the
DeploymentId (FR-038 to FR-042).

| Field | `shared-us` | `dev-staging` | `prod-us` |
|---|---|---|---|
| serves | telemetry, VPC, ECR, backups, budget | staging environment | production environment |
| `deployment_id` (workspace variable) | `shared-us` | `dev-staging` | `prod-us` |
| `environment` / `DEPLOYMENT_ENVIRONMENT` | — | `staging` | `production` |
| hostname | `telemetry.rentsync.org` | `pms-staging.rentsync.org` | `pms.rentsync.org` |
| HCP workspace | `rentsync-shared-us` (manual apply) | `rentsync-dev-staging` (auto-apply) | `rentsync-prod-us` (manual apply) |
| GitHub Environment | — | `dev-staging` (no reviewer) | `prod-us` (required reviewer: operator) |
| own VPC / subnet (ADR-0008) | `10.40.0.0/16` / `10.40.1.0/24` | `10.41.0.0/16` / `10.41.1.0/24` | `10.42.0.0/16` / `10.42.1.0/24` |
| private IP (configuration) | `10.40.1.10` | `10.41.1.20` | `10.42.1.30` |
| peered with | both environment VPCs | `shared-us` only | `shared-us` only |
| name prefix | `rentsync-shared-us-` | `rentsync-dev-staging-` | `rentsync-prod-us-` |
| SSM prefix | `/rentsync/shared-us/` | `/rentsync/dev-staging/` | `/rentsync/prod-us/` |
| database name | `openobserve_shared_us` (metadata) | `mock_pms_dev_staging` | `mock_pms_prod_us` |
| `DeploymentId` tag and `deployment.id` | `shared-us` | `dev-staging` | `prod-us` |

**Validation**: `^[a-z][a-z0-9-]{1,14}[a-z0-9]$`, a Terraform `validation` block in both roots.

**Derived names** (`<id>` = DeploymentId, `<id_>` = the same with `_` for `-`):

| Resource | Pattern |
|---|---|
| EC2 instance `Name`, ENI, EIP, data volume, security group | `rentsync-<id>-host`, `-eni`, `-eip`, `-data`, `-sg` |
| IAM role and instance profile | `rentsync-<id>-host` |
| SSM parameters | `/rentsync/<id>/...` |
| Postgres database | `mock_pms_<id_>`, set in `DATABASE_URL` |
| ECR repository (owned by `shared-us`) | `shared-us/mock_pms` |
| VPC, subnet, IGW, route table (each deployment owns its own) | `rentsync-<id>-vpc`, `-subnet`, `-igw`, `-rt` |
| peering connection to shared (each environment) | `rentsync-<id>-to-shared` |
| DLM policy, budget (owned by `shared-us`) | `rentsync-shared-us-*` |

Tags on every resource, set through AWS provider `default_tags`:

- `DeploymentId = <id>`;
- `Project = rentsync`;
- `ManagedBy = terraform`.

**Side by side**: a further deployment, e.g. `pr-42`, needs only a new workspace on the
`environment` root and its variables: `deployment_id`, `hostname`, its own `vpc_cidr` and
`subnet_cidr` (the next free range, e.g. `10.43.0.0/16`), `private_ip`, and secrets.
None of the three existing deployments, and no bootstrap policy, changes (FR-042).

**Rule**: the two environment deployments share no application data, secrets, volumes or roles
(FR-015), and no network: each has its own VPC with no route to the other (FR-007, ADR-0008).
Everything they share is owned by `shared-us`: the ECR repository, the telemetry ingest endpoint
and its credentials, and the backup policy. Each environment reaches the telemetry endpoint over
its own peering connection.

## Host

| Field | Notes |
|---|---|
| deployment | Its DeploymentId (tag `DeploymentId`), which deploys target. Environment hosts also carry `rentsync:deployable`: `true`, which the release role's `ssm:SendCommand` permission requires, or `protected` for production (`protected = true`), which only the prod-us role may touch |
| instance | `t4g.micro` (environments) or `t4g.small` (telemetry), Amazon Linux 2023 arm64, pinned AMI. Replaceable |
| network interface | Standalone ENI with a fixed private IP. **Survives replacement** |
| Elastic IP | Associated with the ENI. **Survives replacement**. Output for DNS |
| root disk | 16 GiB gp3, encrypted. Disposable |
| data volume | 10 GiB gp3, encrypted, `prevent_destroy`, tag `rentsync:backup=daily`, mounted at `/srv/data`. **Survives replacement** |
| instance role | `rentsync-<deployment_id>-host`: SSM core, ECR read, `ssm:GetParameter(s)` on its prefixes, `ssm:PutParameter` on its own `image_tag` and `previous_image_tag` (environment hosts only) |

**Lifecycle**:

```text
(absent) --apply--> booting --rentsync-boot ok--> running --healthz ok--> healthy
healthy --user_data/AMI/type change--> replaced (old instance destroyed, volume + ENI + EIP reattached) --> booting
healthy --reboot / stop-start--> booting (systemd restarts everything, no manual step)
```

**Filesystem layout** on `/srv/data`:

| Path | Host | Contents |
|---|---|---|
| `postgres/` | environment | Postgres 16 data directory |
| `caddy/` | all | Caddy `/data`: certificates, Let's Encrypt ACME account |
| `receiver/` | environment | Receiver JSONL logs (quickstart only) |
| `openobserve/` | telemetry | OpenObserve `ZO_DATA_DIR` |
| `openobserve-db/` | telemetry | Metadata Postgres data directory |

Files the host writes outside `/srv/data`, all regenerated on boot:

- `/run/rentsync/env`: tmpfs, mode 0600, rendered from SSM.
- `/opt/rentsync/*`: Compose file, Caddyfile and Collector config, written from user data.

## Secret (SSM `SecureString`, written via `value_wo`)

| Parameter | Source | Read by |
|---|---|---|
| `/rentsync/<deployment_id>/admin_token` | HCP sensitive variable `admin_token` (≥ 32 chars, not the example) | that environment's host |
| `/rentsync/<deployment_id>/postgres_password` | `ephemeral "random_password"` (32 chars) | that environment's host |
| `/rentsync/shared-us/openobserve/root_password` | HCP sensitive variable `openobserve_root_password` | telemetry host |
| `/rentsync/shared-us/openobserve/db_password` | `ephemeral "random_password"` | telemetry host |
| `/rentsync/shared-us/openobserve/ingest/password` | the same value as `root_password` (R8 trade-off) | environment hosts |

Each secret has a matching `*_version` number variable. Bumping it rewrites the value. Values
never appear in state, plan output or logs (FR-024).

Non-secret parameters (`String`):

| Parameter | Written by | Purpose |
|---|---|---|
| `/rentsync/shared-us/openobserve/root_email` | Terraform | UI sign-in user |
| `/rentsync/shared-us/openobserve/ingest/user` | Terraform | Collector basic-auth user |
| `/rentsync/<deployment_id>/image_tag` | `rentsync-deploy` after a healthy deploy. Terraform creates it with `ignore_changes = [value]` and initial value `none` | image to run at boot and after replacement: `<sha>@sha256:<digest>` for releases, which pins the exact image |
| `/rentsync/<deployment_id>/previous_image_tag` | `rentsync-deploy` | rollback target |

## Release

| Field | Notes |
|---|---|
| tag | Full 40-character git SHA. Immutable in ECR |
| image | `<aws-account-id>.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms:<sha>`, `linux/arm64` |
| version reported | `SERVICE_VERSION` = the same SHA, in `/healthz.version` and in `service.version` telemetry |
| deployment record | The GitHub Actions run (who approved, when), plus the per-environment `image_tag` and `previous_image_tag` in SSM |

**State transitions per environment**:

```text
image_tag=A --deploy B ok--> image_tag=B, previous=A
image_tag=A --deploy B fails health--> stack back on A, image_tag=A (unchanged), workflow red
image_tag=B, previous=A --rollback--> image_tag=A, previous=B
image_tag=A --deploy A--> no-op success
```

## Backup

| Field | Notes |
|---|---|
| source | Any volume tagged `rentsync:backup=daily`, meaning the three data volumes |
| schedule | Daily at 05:00 UTC (DLM) |
| retention | 7 snapshots (FR-032) |
| consistency | Crash-consistent; Postgres recovers through WAL |
| tags | Copied from the volume (`DeploymentId`), so each snapshot shows which deployment it came from |

## Workspace

| Name | Root | Auto-apply | Remote state shared with |
|---|---|---|---|
| `rentsync-shared-us` | `infra/terraform/shared` | off | `rentsync-dev-staging`, `rentsync-prod-us` |
| `rentsync-dev-staging` | `infra/terraform/environment` | on | — |
| `rentsync-prod-us` | `infra/terraform/environment` | off | — |

All three workspaces:

- belong to organization `craig-personal`, project `RentSync`;
- are VCS-driven from `main`;
- use Terraform 1.16.x;
- get the project variable set `TFC_AWS_PROVIDER_AUTH` / `TFC_AWS_RUN_ROLE_ARN`.

## DNS record (manual, NameCheap)

| Host record | Type | Value |
|---|---|---|
| `pms-staging` | A | `rentsync-dev-staging` output `public_ip` |
| `pms` | A | `rentsync-prod-us` output `public_ip` |
| `telemetry` | A | `rentsync-shared-us` output `telemetry_public_ip` |

TTL: 5 minutes during bring-up, then Automatic. Records never change after the first apply,
because the Elastic IPs survive host replacement.
