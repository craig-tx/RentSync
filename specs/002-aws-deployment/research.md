# Research: AWS Deployment of the Mock PMS

**Feature**: `002-aws-deployment` | **Date**: 2026-10-21 | **Plan**: [plan.md](plan.md)

Each entry gives the decision, the reason for it, and the alternatives considered. Entries
marked **ADR** are significant under Constitution IX and get a record in `docs/adr/` during
implementation.

## R1. Terraform layout and workspaces

**Decision**: There are two root modules and one shared child module under `infra/terraform/`.

| Root | HCP workspace(s) | Holds |
|---|---|---|
| `shared/` | `rentsync-shared-us` | VPC, public subnet, internet gateway, route table; ECR repository; telemetry host; backup (DLM) policy; monthly budget |
| `environment/` | `rentsync-dev-staging`, `rentsync-prod-us` | One environment host, its security group, instance role and its secrets in SSM |
| `modules/host/` | (child module) | EC2 instance, fixed-IP network interface, Elastic IP, durable data volume and attachment, instance profile, cloud-init user data |

- Staging and production run **the same root**. They differ only in workspace variables
  (`deployment_id`, `environment`, `hostname`, `private_ip`, `instance_type`) (FR-002, R17).
- All three workspaces live in HCP Terraform organization `craig-personal`, in project
  `RentSync`. Each is VCS-driven from this repository, with its own working directory.
- The environment workspaces read the shared workspace's outputs through
  `terraform_remote_state` with the `remote` backend. This is the built-in mechanism. It needs
  no extra provider or token: HCP Terraform authorizes the read when `rentsync-shared-us` shares
  its state with the two environment workspaces, which is set once during bootstrap.
- Apply order is shared first, then staging, then production. Teardown runs in reverse.
- Approvals (FR-003):
  - `rentsync-dev-staging`: auto-apply on.
  - `rentsync-shared-us` and `rentsync-prod-us`: auto-apply off, so every apply needs a human
    to click "Confirm & apply". Shared changes affect production too, because they touch the
    VPC and the telemetry host, so they get the same gate.
- Drift (FR-005): HCP Terraform health assessments (drift detection) are turned on per
  workspace where the plan tier allows it. Any plan shows drift in all cases.

**Alternatives considered**:

- One root per environment directory (`envs/staging`, `envs/production`) calling a module:
  more files, and two places to keep identical.
- Terraform CLI workspaces: these do not map to HCP's per-workspace variables and approvals.
- The `tfe_outputs` data source: it needs the `tfe` provider and a token stored in the
  workspace.
- The VPC in its own workspace: adds a fourth workspace with no benefit at this size.

## R2. HCP Terraform to AWS authentication — dynamic provider credentials

**Decision**: Use HCP Terraform **dynamic provider credentials** (FR-004).

- An IAM OIDC identity provider for `https://app.terraform.io` (audience
  `aws.workload.identity`).
- One IAM role, `rentsync-hcp-terraform`. Its trust policy accepts
  `sub` matching `organization:craig-personal:project:RentSync:workspace:rentsync-*:run_phase:*`.
- A variable set on the `RentSync` project carries `TFC_AWS_PROVIDER_AUTH=true` and
  `TFC_AWS_RUN_ROLE_ARN=<role arn>`. Neither is secret.
- The bootstrap runbook creates the provider and the role by hand in the AWS console. No access
  key is ever created. The role's permission scope is in
  [contracts/bootstrap-iam.md](contracts/bootstrap-iam.md). IAM permissions are limited to the
  `rentsync-*` name prefix.

**Alternatives considered**:

- Static access keys in workspace variables: forbidden by FR-004.
- Separate plan and apply roles (`TFC_AWS_PLAN_ROLE_ARN` / `TFC_AWS_APPLY_ROLE_ARN`): better
  least privilege, but it doubles the bootstrap. Recorded as a production difference.
- One role per workspace: same reason.

## R3. Region, availability zone and addressing

**Decision**:

- Region `us-east-1`. It is a variable with that default.
- A single availability zone, `us-east-1a` (variable). EBS volumes are zonal, so the host and
  its data volume must share a zone.
- VPC `10.40.0.0/16`, with one public subnet `10.40.1.0/24`. Both CIDRs are `shared-us`
  configuration.
  > **Amended 2026-10-25 (ADR-0008):** every deployment now owns its VPC. `shared-us` keeps
  > `10.40.0.0/16`; `dev-staging` uses `10.41.0.0/16` (host `10.41.1.20`) and `prod-us`
  > `10.42.0.0/16` (host `10.42.1.30`). Each environment VPC is peered only with the shared VPC,
  > and every subnet stays in the shared availability zone.
- Each host has a **fixed private IP**, supplied as its deployment's configuration and never
  hard-coded (constitution VI): `shared-us` `10.40.1.10`, `dev-staging` `10.40.1.20`,
  `prod-us` `10.40.1.30`. The IP sits on a standalone `aws_network_interface`, attached to the
  instance as its primary interface. The Elastic IP is associated with that interface, not the
  instance.
- Replacing an instance therefore keeps both its public address (FR-008, US5) and its private
  address. The environments' Collectors keep reaching the telemetry host at the `shared-us`
  `otlp_endpoint` output without being reconfigured (edge case "telemetry host replaced").
- The exact attachment argument (`network_interface` or `primary_network_interface`, depending
  on the AWS provider major version) is confirmed when the provider is pinned.

**Alternatives considered**:

- Instance-assigned private IPs: change on replacement and break telemetry.
- A Route 53 private hosted zone: managed DNS, which is out of scope, and it costs money.

## R4. Host operating system, size and architecture

**Decision**:

- **AMI**: Amazon Linux 2023 on **arm64 (Graviton)**. It ships with the SSM agent and chrony,
  which is set to the Amazon Time Sync Service (FR-012, clock edge case). Docker and the
  Compose plugin come from the distribution's packages.
- **AMI pinning**: the AMI ID is a variable, pinned to a specific AMI. It is not a
  `most_recent` lookup, which would make every plan want to replace the hosts. Upgrading the AMI
  is a deliberate variable change, applied staging first. It replaces the host and goes through
  the host-replacement path (US5).
- **Instance type**: `t4g.micro` (2 vCPU burstable, 1 GiB) for the environment hosts and
  `t4g.small` (2 GiB) for the telemetry host. All three started on `t4g.small`; the environment
  hosts moved to `t4g.micro` on 2026-10-27 (operator decision, to cut cost) after the
  measurement and swap below.
  - An environment host runs Puma, the worker, Postgres, Redis, the Collector and Caddy (the
    test receiver only under the `tools` profile). The original estimate was 1–1.3 GiB; the
    measurement below puts it at about 700–750 MiB.
  - OpenObserve plus its Postgres fits in 2 GiB at demo volumes.
  - **Measured 2026-10-26** on the local Compose stack, with the production `mock_pms` image,
    sampling `docker stats` every 2 s. Load: 1,248 events in 35 s, 599 webhook deliveries,
    6,400 HTTP requests from 8 parallel clients, and a first-deploy `bin/setup --deploy`.

    | Container | Idle (MiB) | Peak under load (MiB) |
    |---|---|---|
    | web (Puma) | 56 | 71 |
    | worker | 44 | 48 |
    | Postgres (4 databases locally; a host has 1) | 147 | 168 |
    | Collector | 104 | 108 |
    | Redis | 9 | 14 |
    | Caddy (not in the local stack; typical) | — | ~40 |
    | **containers** | | **~450** |
    | test receiver (`tools` profile only; add when running it) | 49 | 55 |
    | OpenObserve (telemetry host) | 653 | 949 |

    Adding ~250–300 MiB for the OS, Docker and the SSM agent (estimated, not measured), an
    environment host peaks at ~700–750 MiB. Caveats: Docker Desktop on x86_64, not Graviton.
    The Collector runs with `GOMEMLIMIT` at ~80% of its `memory_limiter` limit (256 MiB), so it
    collects garbage harder before the limiter refuses data.
  - **What the measurement means**:
    - `t4g.nano` (512 MiB) cannot hold the containers.
    - `t4g.micro` (1 GiB, ~900 MiB usable) fits an environment host with ~100–150 MiB to spare.
      That is too little for a deploy's brief peaks without swap.
    - The telemetry host stays `t4g.small`: OpenObserve alone peaked at 949 MiB.
  - **Swap**: every host gets a 1 GiB swap file on the root disk at first boot
    (`rentsync-swap`, module variable `swap_mib`; 0 turns it off), with `vm.swappiness = 10`.
    Swap is used only under memory pressure, so a brief peak slows the host down instead of
    the kernel killing a container. It is what makes `t4g.micro` workable for the environment
    hosts; runbook §Changing a host's instance type says how to check memory and how to go
    back to `t4g.small` for one environment.
  - The instance type is a variable. `t3.small` (amd64) is the fallback if an image lacks
    arm64.
- **Image architecture**: the mock PMS image is built for `linux/arm64` on GitHub's native
  `ubuntu-24.04-arm` runner, which is free for public repositories. This repository is public.
  The other images (Caddy, Postgres 16, Redis 7, otel-collector-contrib, OpenObserve) publish
  arm64 variants. Implementation verifies each pinned tag, and falls back to `t3.small` for any
  host whose image lacks arm64.
- **Disks**: a gp3 root disk (16 GiB) and a gp3 data volume (10 GiB), both encrypted with the
  AWS-managed EBS key. IMDSv2 is required. There is no key pair.

**Alternatives considered**:

- Ubuntu: the SSM agent is a snap and needs more setup.
- `t3.small`: costs about 20% more per host.
- Building arm64 under QEMU: slow Ruby native-extension builds would put SC-005's 15 minutes
  at risk.

## R5. Cost estimate (SC-009)

us-east-1 on-demand prices, 730 hours a month:

| Item | Quantity | Monthly (USD) |
|---|---|---|
| `t4g.micro` (environment hosts) | 2 × $0.0084/h | 12.26 |
| `t4g.small` (telemetry host) | 1 × $0.0168/h | 12.26 |
| Public IPv4 (in-use Elastic IPs are charged) | 3 × $0.005/h | 10.95 |
| gp3 root disks | 3 × 16 GiB × $0.08 | 3.84 |
| gp3 data volumes | 3 × 10 GiB × $0.08 | 2.40 |
| EBS snapshots (7 daily, incremental, ~5 GiB changed) | ~5 GiB × $0.05 | ~0.25 |
| ECR (lifecycle keeps 100 images) | ~2 GiB | ~0.20 |
| SSM Parameter Store (standard tier), DLM, IAM, budgets (first 2 free) | — | 0.00 |
| Data transfer out (demo traffic) | < 10 GiB | < 0.90 |
| **Total** | | **≈ 43** |

- This is under the $60 ceiling, with about $17 of headroom. With all three hosts on
  `t4g.small` (the original plan) it was ≈ 55.
- The budget is $60 per month. It alerts on actual spend at 80% and 100%, and on forecast
  spend at 100% (FR-035). The forecast alert catches runaway spend before month end.
- Secrets Manager ($0.40 per secret per month), NAT gateways (about $33 each), and load
  balancers (about $16 each) are avoided. Each appears in the production-differences document.

## R6. Host bootstrap: cloud-init, systemd and the durable volume — the data-safety path

**Decision**: The user data is a cloud-init document, rendered by Terraform's `templatefile()`
and gzip-compressed with the built-in `base64gzip()`, which keeps it under the 16 KB limit. It
contains **no secrets**. It writes files from `infra/host/` and enables systemd units. With
`user_data_replace_on_change = true`, a change to host configuration replaces the host, through
the same path US5 exercises.

Boot sequence (`rentsync-boot`, run as `rentsync.service`'s `ExecStartPre`, so its failures are retried with the service; code review 2026-10-21):

1. **Find the data volume** by its stable ID,
   `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol<id without dash>`. On Nitro instances
   the device is not `/dev/xvdf`. Wait up to 5 minutes, because the volume attachment can land
   after the instance boots.
2. **Format only if empty**: run `mkfs.xfs` only when `blkid` reports no filesystem. A
   replacement host must never reformat existing data. A test fixture covers this rule (see
   R15).
3. Mount it at `/srv/data`, through an `fstab` entry keyed by UUID with `nofail`.
4. Create `/srv/data/{postgres,caddy,openobserve,...}`. **Caddy's `/data` directory (its
   certificates and Let's Encrypt ACME account) is on the durable volume**, so a replaced host reuses its
   certificates and does not hit Let's Encrypt rate limits.
5. Write `/etc/docker/daemon.json` with `json-file` logs capped at `max-size: 10m` and
   `max-file: 3` (FR-012).

`rentsync.service` runs `rentsync-deploy --reload` (R9), which renders secrets and starts
Compose. Docker's `restart: unless-stopped` together with the enabled systemd units brings
everything back after a reboot or a stop/start (US5 AC5).

A weekly systemd timer runs `docker image prune -af --filter until=168h`. Rollback pulls from
ECR, so a pruned image is never needed locally (FR-012).

On the Terraform side:

- `aws_ebs_volume.data` has `lifecycle { prevent_destroy = true }` (FR-034).
- `aws_volume_attachment` has `stop_instance_before_detaching = true`, so Postgres is stopped
  cleanly before a detach.
- Replacement is destroy-then-create. The volume and the network interface carry over.

**Alternatives considered**:

- Pushing host config through SSM parameters: the standard tier's 4 KB limit is too small for
  the Collector config.
- An S3 bucket for config: adds a bucket and a sync step, and in-place config changes would
  bypass the tested replacement path.
- Ansible or Packer images: new dependencies, more than this demo needs.

## R7. Container layout on each host

**Environment host** (`infra/host/compose.env.yaml`):

| Service | Image | Network exposure |
|---|---|---|
| `caddy` | `caddy:2` (pinned) | host 80/443; proxies to `mock_pms:4001` |
| `mock_pms` | `<ecr>/rentsync/mock_pms:<sha>` | internal only |
| `mock_pms_worker` | same image | none |
| `postgres` | `postgres:16` | internal; data on `/srv/data/postgres` |
| `redis` | `redis:7` | internal; no persistence needed (short-lived data, 001 R8/R12) |
| `otel-collector` | `otel/opentelemetry-collector-contrib:0.162.0` | none; sends to `10.40.1.10:5080` |
| `receiver` | same mock PMS image, `tools` profile | internal; for the quickstart only |

- The service names match the local `compose.yaml`, so the Collector's scrape target
  (`mock_pms:4001`) and the 001 tool scripts work unchanged.
- The Compose file never contains `build:` and never loads `compose.override.yaml`.
- Caddy:
  - redirects HTTP to HTTPS (FR-014);
  - answers **`/metrics` with 404 from the public side**, because only the Collector scrapes it
    on the internal network;
  - forwards `X-Request-Id` unchanged.
- `stop_grace_period: 30s` on the worker lets an in-flight delivery finish. Anything cut off is
  retried from the outbox anyway (FR-030, 001 R6).

**Telemetry host** (`infra/host/compose.telemetry.yaml`):

| Service | Image | Network exposure |
|---|---|---|
| `caddy` | `caddy:2` | host 80/443; proxies the UI to `openobserve:5080` |
| `openobserve` | `openobserve/openobserve:v1.0.4` | host `10.40.1.10:5080` (OTLP ingest; the security group admits only the environment hosts) |
| `openobserve-db` | `postgres:16` | internal; metadata store (`ZO_META_STORE=postgres`) on `/srv/data/openobserve-db` |

OpenObserve's data directory is `/srv/data/openobserve` (FR-020).

## R8. Telemetry path (FR-016, FR-011, US3)

**Decision**: Each environment's Collector exports OTLP/HTTP to the `shared-us` output
`otlp_endpoint`, which is `http://10.40.1.10:5080/api/default`.

- It authenticates with basic auth, using the OpenObserve credentials read from SSM.
- The traffic stays inside the VPC. The telemetry security group admits 5080 only from members of
  `rentsync-shared-us-otlp-client`. Every environment host attaches that group, so adding a
  deployment never edits a shared rule. Port 5080 is never open to the internet (FR-011, US3 AC5).
  > **Amended 2026-10-25 (ADR-0008):** the traffic now crosses each environment's peering
  > connection, staying on the private AWS network. The `otlp-client` group is gone, because a
  > security group can't be attached across VPCs. Each environment adds its own standalone rule
  > on the telemetry group, admitting 5080 from its subnet, so adding a deployment still edits no
  > shared code.
- `infra/otel/collector.yaml` gets one change: its exporter endpoint becomes
  `${env:OPENOBSERVE_OTLP_ENDPOINT}`. Local `.env.example` sets it to
  `http://openobserve:5080/api/default`. Local and deployed hosts then share one config file,
  and the backend stays configuration only (Constitution VI).
- `DEPLOYMENT_ENVIRONMENT=staging|production` is already carried as `deployment.environment` by
  the 001 logging and metrics code. `DEPLOYMENT_ID` is new: it is carried as `deployment.id` on
  logs, and on metrics through the `target_info` label `deployment_id`, which the Collector's
  `transform/metrics_resource` promotes alongside the existing ones (R10, R17).
  `SERVICE_VERSION` is set from the image's `GIT_SHA` build argument.
- When the telemetry host is down, the Collector's in-memory queue (1000 batches) absorbs the
  outage and then drops data, counting what it drops. The mock PMS is unaffected (US3 AC4,
  001 R16).

**Trade-off**: the Collectors use the OpenObserve root credentials, and OTLP crosses the VPC in
plain HTTP. In production each environment would have its own ingest-only OpenObserve service account, with
TLS on the ingest path. Both go in the production-differences document.

**Alternatives considered**:

- Ingest through the public Caddy endpoint: telemetry would leave the VPC, contradicting
  US3 AC5.
- A per-environment OpenObserve service account created through the API after boot: extra
  moving parts at bring-up.

## R9. Releases: build once, deploy by SSM Run Command — **ADR**

**Decision**: Releases happen **outside Terraform**, in GitHub Actions (FR-026 to FR-030).
Terraform only creates the place an image runs. The deployed tag is runtime state, held in SSM.

**`.github/workflows/release.yml`** is triggered by `workflow_run` when `CI` completes
successfully on `main`.

1. **`build`** (runs on `ubuntu-24.04-arm`):
   - assumes `rentsync-github-build` through GitHub OIDC. Only jobs on `main` are trusted, and
     no other role can push images;
   - builds `mock_pms` with `GIT_SHA=<full sha>`;
   - pushes `<aws-account-id>.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms:<sha>`;
   - outputs the image **digest**.

   The ECR repository has **immutable tags**, so a tag is always one image. The build skips the
   push if the tag already exists, which makes re-runs idempotent. Both deploys pass
   `<sha>@sha256:<digest>`, so each host pulls exactly the image the build produced.

   *Security review, 2026-10-21:* release roles once trusted `environment:*`, and builds also
   ran under the deploy role. A branch job naming a new GitHub Environment could then push an
   image under an upcoming commit's tag, and that image would reach production past the
   reviewer. Each role now trusts exact subjects only (contracts/bootstrap-iam.md), and deploys
   pin digests.
2. **`deploy-dev-staging`** (GitHub Environment `dev-staging`, named by DeploymentId):
   - `aws ssm send-command` with `AWS-RunShellScript`, targeted at
     `tag:DeploymentId=dev-staging`, runs `rentsync-deploy <sha>`;
   - it waits for the command, prints its output, then checks
     `https://pms-staging.rentsync.org/healthz` from outside for `status=ok`,
     `version=<sha>` and `deployment_id=dev-staging`.
3. **`deploy-prod-us`** (GitHub Environment `prod-us`, **required reviewer: the operator**): the
   same steps against the production host and URL, with the **same tag**. Its approval gate is
   the promotion approval (FR-027). Nothing is rebuilt.

Each deploy job is one call to a reusable workflow that takes `deployment_id`. The URL comes
from the GitHub Environment variable `SITE_URL`. A side-by-side deployment adds an Environment
and one job, with no new logic.

**`.github/workflows/deploy.yml`** (`workflow_dispatch`) takes `deployment_id` and `image_tag`,
or `rollback: true`. It is the one documented action for rollback (FR-029) and for manual
redeploys. Production runs of it pass through the same Environment approval.

**`rentsync-deploy`** runs on the host. Its interface is in
[contracts/host-interface.md](contracts/host-interface.md).

1. Take a `flock`, so concurrent deploys are serialized.
2. Read secrets from SSM into `/run/rentsync/env`. `/run` is tmpfs, and the file is mode 0600.
3. Log in to ECR and pull the tag.
4. Run `bin/setup --deploy` once in a temporary container (R10).
5. Run `docker compose up -d`.
6. Poll the internal `/healthz` until it reports `status=ok` and `version=<tag>`, for up to
   120 s.
7. **On success**: write `/rentsync/<deployment_id>/previous_image_tag` ← the old value, then
   `/rentsync/<deployment_id>/image_tag` ← the tag.
8. **On failure**: bring the previous tag back up, re-check health, and exit non-zero. The
   workflow fails and GitHub notifies the operator (FR-028, US4 AC3).

Deploying the tag that is already running and healthy does nothing and succeeds (Constitution
II).

**Migrations and rollback**: a rollback runs N−1's code against N's schema. Migrations must
therefore be **expand-only** within a release (add columns or tables, never drop or rename),
and contraction happens a release later. The runbook states this rule. 001's migrations already
follow it.

**Alternatives considered**:

- The image tag as a Terraform variable: every release becomes an HCP run, user-data changes
  can replace hosts, and drift reports get noisy.
- A pull-based agent or Watchtower: adds a dependency and makes "stop on failed health check"
  harder.
- CodeDeploy: new service and agent, more than needed.

## R10. Application changes to feature 001 code (test-first)

Four small changes. Each gets a failing spec first (Constitution III, CLAUDE.md).

1. **`/healthz` reports the build and the deployment.** Add `version: Settings.service_version`
   and `deployment_id: Settings.deployment_id` to the `/healthz` and `/healthz/live` bodies.
   FR-028 and US4 AC1 need the build identifier in the health output. Spec:
   `spec/api/ops_spec.rb`.
2. **`bin/setup --deploy`**: a non-destructive setup for deployed hosts. Today `bin/setup` always
   runs `Seed::Reset`, which wipes clients and grants, and it requires `TEST_DATABASE_URL`.
   Either would break FR-030 on every release. `--deploy`:
   - ensures the main database exists and migrates it, without touching the test database;
   - seeds **only when the database has no operators** (the first deploy);
   - is idempotent: running it twice leaves the same end state.

   Before writing it, check what `MockPms.boot!` already does since commit 5160138 (creating
   the database at boot), so nothing is duplicated.
3. **Collector endpoint from configuration** (R8): `infra/otel/collector.yaml` reads its
   endpoint from `OPENOBSERVE_OTLP_ENDPOINT`, and `.env.example` gains that variable. The CI
   `telemetry-smoke` job proves the local path still works.
4. **`deployment.id` everywhere** (FR-041, constitution v1.2.0):
   - `Settings.deployment_id` reads `DEPLOYMENT_ID` and validates it against the constitution's
     format;
   - every JSON log line carries `deployment.id`, and `target_info` carries `deployment_id`;
   - the Collector moves both into the resource;
   - `.env.example` sets `DEPLOYMENT_ID=local-dev`, and its database names become
     `mock_pms_local_dev` and `mock_pms_local_dev_test`, which brings local development into
     compliance too;
   - `bin/telemetry_smoke` asserts that `deployment.id` arrives.

   Specs: the logger spec, the metrics exposition spec and the settings spec.

## R11. Secrets — **ADR**

**Decision**: Secrets are stored in **SSM Parameter Store `SecureString`** (standard tier, the
AWS-managed `aws/ssm` key). Terraform writes them with **write-only arguments**, so values are
never stored in state or shown in plans (FR-022 to FR-024).

- `aws_ssm_parameter` with `value_wo` and `value_wo_version`. Changing the version is what
  triggers a rewrite.
- Operator-supplied secrets are HCP Terraform **sensitive** workspace variables, declared in
  Terraform as `ephemeral = true`, so they stay out of plan files and state:
  - `admin_token` (per environment);
  - `openobserve_root_password` (shared).
- Generated secrets use **`ephemeral "random_password"`** (random provider) passed straight into
  `value_wo`:
  - each environment's `postgres_password`;
  - the telemetry `openobserve_db_password`.

  The generator yields a fresh value on every run, but it is written only when its
  `*_version` variable changes. The stored value is stable.
- Both features were confirmed against the provider documentation on 2026-10-21: write-only
  arguments on `aws_ssm_parameter`, and the ephemeral `random_password` resource. They need
  **Terraform ≥ 1.11**. All three HCP workspaces are pinned to the same Terraform version as
  local (1.16.x).
- Hosts read only their own path (FR-023):
  - an environment host reads `/rentsync/<deployment_id>/*` and `/rentsync/shared-us/openobserve/ingest/*`;
  - the telemetry host reads `/rentsync/shared-us/*`.

  Each instance role grants `ssm:GetParameter(s)` on those ARNs. Decryption with the AWS-managed
  key is allowed through SSM.
- **Rotation** (edge case): change the HCP variable or bump `<name>_version`, apply, then run
  `deploy.yml` with the current tag, which re-renders the env file. The Postgres password also
  needs an `ALTER USER` before the restart, because the `postgres` image sets it only on first
  initialization. The runbook has the exact steps.
- `FR-025`: the `environment` root has a `validation` that rejects an `admin_token` shorter than
  32 characters or equal to `change-me-admin-token`.

**Alternatives considered**:

- Secrets Manager: $0.40 per secret per month, and rotation lambdas the demo doesn't need.
- Managed `random_password`: stores the value in state.
- Secrets in user data: visible in the console and in state.

## R12. Network rules and administrative access

**Decision**:

| Security group | Inbound | Outbound |
|---|---|---|
| `rentsync-<id>-sg` (each environment deployment) | TCP 80, 443 from `0.0.0.0/0` | all (ECR, SSM, ACME, OTLP) |
| `rentsync-shared-us-otlp-client` (attached by every environment host) | none | all |
| `rentsync-shared-us-sg` (telemetry host) | TCP 80, 443 from `0.0.0.0/0`; TCP 5080 from `rentsync-shared-us-otlp-client` | all |

> **Amended 2026-10-25 (ADR-0008):** `rentsync-shared-us-otlp-client` no longer exists. The
> telemetry group admits TCP 5080 from each environment's subnet (for example `10.41.1.0/24`), one
> standalone rule per environment, owned by that environment's state.

- No port 22, and no key pair (FR-009).
- Shell access is through **SSM Session Manager**: the instance role has
  `AmazonSSMManagedInstanceCore`, and the agent connects outbound (FR-010).
- IPv6 is not enabled. The scan check (SC-003) uses `nmap -Pn -p 1-65535`.

## R13. TLS and Caddy

**Decision**: Caddy 2 handles automatic HTTPS from Let's Encrypt (FR-014).

- The `acme_ca` variable selects the Let's Encrypt staging endpoint for first bring-up (DNS edge
  case). The runbook switches it to production once DNS resolves.
- Caddy retries with exponential backoff, and keeps its state on the durable volume (R6), which
  avoids rate limits on retries and replacements.
- Renewal is automatic, about 30 days before expiry (edge case "certificate renewal").
- The operator contact email for ACME is a non-secret workspace variable.

## R14. Backups and restore (FR-031 to FR-034)

**Decision**: one **Data Lifecycle Manager** policy, in the shared workspace, targets volumes
tagged `rentsync:backup=daily`.

- It takes a snapshot daily at 05:00 UTC and keeps 7.
- Snapshots are crash-consistent. Postgres recovers from them through WAL replay.
- The data volumes of all three hosts carry the tag.

**Restore procedure** (US5 AC3, runbook):

1. Release the current volume from Terraform's management with
   `terraform state rm 'module.host.aws_ebs_volume.data'`, run against the deployment's HCP
   workspace. The volume stays in AWS, untouched.
2. Set the `data_snapshot_id` workspace variable to the chosen snapshot.
3. Apply. Terraform creates a new volume from the snapshot and replaces the attachment and the
   instance.

This is deliberate by construction: `prevent_destroy` cannot be switched off by a variable, so
replacing a data volume always needs an explicit, recorded operator action (FR-034). The old
volume is kept, unmanaged, for forensics, and deleted by hand later. Teardown uses the same
release step (runbook §Teardown).

*Implementation note:* the plan first called for a `removed { … destroy = false }` block.
Terraform rejects a `removed` block for a resource the module still declares, so the procedure
uses `terraform state rm`, the equivalent explicit action. Full steps are in runbook
§Backup restore. Task T083 rehearses it on `dev-staging`.

**Alternatives considered**:

- AWS Backup: more setup for the same result.
- Nightly `pg_dump` to S3: optional per the spec; not needed when volume snapshots are enough.

## R15. Testing the infrastructure

| Layer | Tool | Runs in |
|---|---|---|
| Terraform format and validity | `terraform fmt -check -recursive`, `terraform validate` per root | new CI job `infra` |
| Terraform behavior | `terraform test` with `mock_provider "aws"`: no 22/5080 from the internet; `prevent_destroy` present; fixed IPs; `admin_token` validation; no `value =` on a SecureString | `infra` job |
| Host scripts | `shellcheck` (preinstalled on GitHub runners), plus a script test for `rentsync-boot`'s "format only if no filesystem" rule against a loop device | `infra` job |
| Application changes | RSpec (existing) | `test` job |
| End-to-end | quickstart.md against staging, then production | operator, after each environment comes up |

There are no new test dependencies: `terraform test`, `shellcheck` and loop devices are already
on the runner.

## R16. ECR repository

**Decision**: `shared-us/mock_pms`, in the shared workspace.

- Tags are immutable, and images are scanned on push.
- A lifecycle policy keeps the last 100 images. prod-us moves only on approval, so the image it runs, and its rollback target, must outlive many merges.
- Host roles get read access; the GitHub Actions role gets push access.
- The repository has `force_delete = false`. Teardown empties it first (runbook).
- The repository is owned by `shared-us`, so its name starts with that DeploymentId. Every
  environment deployment pulls from it, which is what lets production run exactly the image that
  staging verified.

## R17. DeploymentId — side-by-side deployments (constitution v1.2.0, FR-038 to FR-042)

**Decision**: Both roots take a `deployment_id` variable and validate it with
`^[a-z][a-z0-9-]{1,14}[a-z0-9]$`. Everything a deployment owns is derived from it in one
`locals` block:

- `name = "rentsync-${var.deployment_id}"`, used as the prefix of every resource name and IAM
  role;
- `ssm_prefix = "/rentsync/${var.deployment_id}"`;
- `db_name = "mock_pms_${replace(var.deployment_id, "-", "_")}"`.

The AWS provider sets `default_tags { tags = { DeploymentId = var.deployment_id, Project =
"rentsync", ManagedBy = "terraform" } }`, so every resource is tagged without per-resource code.

The first three DeploymentIds:

| DeploymentId | Workspace | Serves |
|---|---|---|
| `shared-us` | `rentsync-shared-us` | VPC, ECR, telemetry host, backups, budget |
| `dev-staging` | `rentsync-dev-staging` | staging environment |
| `prod-us` | `rentsync-prod-us` | production environment |

Workspaces are named `rentsync-<deployment_id>`. The `environment` root reads the shared
deployment through `var.shared_workspace`, so a deployment can also point at a different shared
deployment, such as a future `shared-eu`.

**What makes side-by-side work**: names never collide, because they all carry the ID.

- Addresses are configuration (R3).
- The release role's permissions key on the tag `rentsync:deployable = true`, so they name no
  deployment. Its trust lists exact GitHub Environments: adding a deployment adds one line
  there, a deliberate security exception to "no shared change" (security review 2026-10-21; a
  wildcard let any branch job assume the role). Production hosts are `protected`, and a
  separate role trusted only for the `prod-us` Environment deploys them.
- The OTLP path uses a membership security group (R8, R12).

Adding `pr-42` is therefore:

1. a new workspace on the `environment` root, with its variables;
2. a GitHub Environment and one deploy job;
3. an A record.

No existing deployment's code, variables or IAM changes (FR-042). The data volume's
`prevent_destroy` still applies, so tearing `pr-42` down uses the same documented override.

**Telemetry and cost**: `deployment.id` lets the shared OpenObserve filter by deployment (R10).
Activating `DeploymentId` as a cost allocation tag in Billing gives per-deployment cost in Cost
Explorer (bootstrap, [contracts/bootstrap-iam.md](contracts/bootstrap-iam.md)).

**Testing**: `terraform test` cases cover the following.

- An invalid ID is rejected.
- Two mocked runs with different IDs produce disjoint resource names and SSM paths.
- Every resource that supports tags has `DeploymentId`, through provider `default_tags`.

**Alternatives considered**:

- Naming resources by environment (the earlier draft): a second staging-like stack would
  collide.
- Separate AWS accounts per deployment: the real-production answer, recorded under FR-036, but
  out of scope.

## Resolved unknowns

There were no `NEEDS CLARIFICATION` markers in Technical Context. The spec's open defaults are
settled here:

- hostnames: in the spec's Assumptions;
- cost ceiling: R5;
- staging is applied automatically, and releases to it are automatic on a green `main`
  (R1, R9).
