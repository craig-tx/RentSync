# Implementation Plan: AWS Deployment of the Mock PMS

**Branch**: `002-aws-deployment` | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-aws-deployment/spec.md`

**Note**: `/speckit-plan` was run without arguments. The fixed inputs come from the spec's
Assumptions: region `us-east-1`, HCP Terraform organization `craig-personal`, and hostnames
under `rentsync.org`.

## Summary

Run the feature 001 mock PMS on AWS as two independent environments, staging and production,
plus one shared OpenObserve host. All of it lives in a single VPC and is applied from HCP
Terraform. This is a cost-conscious demo, about $55 per month.

The main technical choices:

- **Every deployment is named by its DeploymentId** (constitution v1.2.0, R17).
  - The first three are `shared-us`, `dev-staging` (staging) and `prod-us` (production).
  - Resource names, IAM roles, SSM paths and database names derive from the ID.
  - Every resource carries a `DeploymentId` tag, and all telemetry carries `deployment.id`.
  - A further deployment, such as `pr-42`, can run side by side in the same AWS account without
    touching the others.
- **Three HCP workspaces over two Terraform roots**, named `rentsync-<deployment_id>`.
  - `shared` (`shared-us`) holds the VPC, ECR, the telemetry host, backups and the budget.
  - `environment` is one root used by both `dev-staging` and `prod-us`.
  - A `host` module builds each EC2 host. The host's public IP (Elastic IP), private IP
    (standalone network interface) and data volume all survive the instance being replaced.
- **Hosts are disposable; data is not.**
  - Each host runs Amazon Linux 2023 on Graviton, set up by cloud-init.
  - Its Postgres, Caddy certificates and OpenObserve data sit on a separate encrypted EBS
    volume. The volume has `prevent_destroy`, and AWS Data Lifecycle Manager takes daily
    snapshots, keeping 7.
- **Secrets never reach state.**
  - HCP sensitive variables and Terraform-generated ephemeral passwords are written to SSM
    Parameter Store `SecureString` through write-only arguments.
  - Each host's role reads only its own parameter path.
- **No inbound admin port.** Only 80 and 443 are public, and shell access is through SSM
  Session Manager. Telemetry is ingested on 5080 only from inside the VPC.
- **Releases run outside Terraform** (ADR):
  - GitHub Actions builds one arm64 image per commit and pushes it to ECR with an immutable tag.
  - SSM Run Command deploys it to staging, and then, after a GitHub Environment approval,
    deploys the same tag to production.
  - The deploy script on the host migrates, health-checks the reported version, and rolls back
    by itself if the check fails.
- **Four small test-first changes to feature 001 code**:
  - `/healthz` reports `version` and `deployment_id`;
  - `bin/setup --deploy` migrates and seeds only when empty;
  - the Collector's backend endpoint becomes configuration;
  - logs and metrics carry `deployment.id`, and local development moves to `local-dev` with
    database `mock_pms_local_dev`.
- **Managed cache rejected on cost**: Redis stays a container.

See [research.md](research.md) (R1–R17) for each decision.

## Technical Context

**Language/Version**:

- Terraform 1.16.x (≥ 1.11 is required for write-only arguments). HCP workspaces are pinned to
  the same version.
- Bash for the host scripts (Amazon Linux 2023's bash 5).
- Ruby 3.3 for the feature 001 changes.
- GitHub Actions YAML.

**Primary Dependencies**:

- Terraform providers `hashicorp/aws` (~> 6.x, pinned at implementation) and `hashicorp/random`
  (~> 3.7, for ephemeral passwords).
- Container images: Caddy 2, Postgres 16, Redis 7, otel-collector-contrib 0.162.0 and
  OpenObserve v1.0.4. The last four already run in feature 001.
- GitHub Actions: `aws-actions/configure-aws-credentials`, `aws-actions/amazon-ecr-login`,
  `docker/build-push-action`. Each one is justified in [Dependencies](#dependencies).

**Storage**:

- Per environment, Postgres 16 in a container on an EBS gp3 data volume (10 GiB). Redis is
  short-lived (001 R8/R12).
- The telemetry host keeps OpenObserve's data and its metadata Postgres on its own data volume.
- Secrets live in SSM Parameter Store. Runtime release state (`image_tag`,
  `previous_image_tag`) lives in SSM `String` parameters.

**Testing**:

- `terraform fmt`, `validate` and `terraform test` with mocked providers, for the security
  group, protection and validation rules.
- `shellcheck`, plus a loop-device test of the "never reformat" rule.
- RSpec for the 001 changes.
- End to end: [quickstart.md](quickstart.md) against both public URLs. It reruns the 001
  quickstart §3–§9.

**Target Platform**:

- AWS `us-east-1`, a single availability zone (`us-east-1a`), EC2 `t4g.small`, Amazon Linux
  2023 arm64.
- HCP Terraform, organization `craig-personal`, project `RentSync`.
- GitHub Actions (`ubuntu-latest`; `ubuntu-24.04-arm` for image builds).

**Project Type**: infrastructure-as-code plus a release pipeline for an existing web service.

**Performance Goals**:

- Merge to staging healthy in under 15 minutes; production promotion in under 10 minutes after
  approval (SC-005).
- Rollback in under 10 minutes (SC-006).
- Host replacement in under 30 minutes (SC-007).
- Telemetry visible within 60 s (SC-008).

**Constraints**:

- Steady state under USD 60 per month (SC-009; estimate in R5).
- Only TCP 80 and 443 public (SC-003).
- No long-lived AWS keys anywhere (FR-004).
- No secret values in the repository, state, plan output or logs (FR-024).
- Production changes always need a human approval: HCP manual apply for infrastructure, the
  GitHub Environment reviewer for releases (FR-003, FR-027).

**Scale/Scope**:

- 3 hosts, 3 workspaces, 2 environments and 1 ECR repository.
- About 30 Terraform resources per root.
- Demo traffic: tens of requests per minute.

## Constitution Check

*GATE: must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | How this plan complies | Status |
|---|---|---|
| I. Correctness over cleverness | No financial logic is added. Releases preserve all data, and backups plus `prevent_destroy` guard it (FR-030, FR-034). | ✅ |
| II. Idempotency everywhere | Idempotency keys and what each protects: (1) Terraform resources are convergent, and re-runs after a partial failure converge (edge case). (2) The ECR tag is the git SHA, and tags are immutable, so a re-run build never yields two images for one tag. (3) `rentsync-deploy <tag>` takes a `flock` and does nothing when that tag is already healthy. (4) `bin/setup --deploy` seeds only when `operators` is empty. (5) Write-only secrets are rewritten only when `*_version` changes. | ✅ |
| III. Test-first for domain logic | The 001 changes (`/healthz` version, `setup --deploy`) get failing specs first. Infrastructure rules (ports, protection, token validation) are covered by `terraform test`, written before the resources. No test is weakened. | ✅ |
| IV. Integrations hostile by default | The deployed mock PMS keeps every chaos feature, so the hostile-traffic harness becomes reachable to RentSync. Collector export tolerates a telemetry outage. | ✅ |
| V. Agents propose, humans dispose | No agents in this feature. | N/A |
| VI. Observable by default (v1.2.0) | All telemetry carries `deployment.environment` and `deployment.id` (R10). **DeploymentId** (R17): `prod-us`, `dev-staging` and `shared-us` are validated in both roots. Every owned name derives from the ID: resources, IAM roles, SSM paths, database `mock_pms_<id_>`, Compose project. Addresses are configuration. Every resource gets the `DeploymentId` tag through provider `default_tags`. A side-by-side deployment needs no change to existing ones. Local development moves to `local-dev`. The backend endpoint becomes configuration only (R8). `/healthz` gains `version` and `deployment_id`. Export never blocks requests, and drops are counted (001 R16). | ✅ |
| VII. Secure by default | Secrets live in SSM SecureString, are kept out of state through write-only arguments, and each host reads only its own path. There is no SSH. IMDSv2 and encrypted volumes are on. `/metrics` is not public. The admin token is validated as strong and differs per environment. Repository secret scanning is on. | ✅ |
| VIII. Simplicity | Two roots and one module. No Ansible, Packer, Kubernetes, load balancer or Secrets Manager. Each new dependency is justified below. | ✅ |
| IX. Documented decisions | ADRs to write: 0005 (demo topology: single VPC, one EC2 host per environment, with its production differences), 0006 (releases outside Terraform through SSM Run Command, R9), 0007 (secrets: SSM write-only, R11). | ✅ |
| X. Stateless services | The service processes are unchanged and stateless. One web instance per environment is a deployment choice, not process state: the 001 multi-instance proofs still run on the host (quickstart §4). Caddy and the Collector keep only rebuildable or loss-bounded state. The Collector's queue loss bound is unchanged from 001 R16. | ✅ |

**Gate result (pre-research)**: pass. **Re-check after Phase 1 design**: pass. The contracts
and data model add no state to the service processes, and no unjustified dependency.

## Project Structure

### Documentation (this feature)

```text
specs/002-aws-deployment/
├── plan.md                         # This file
├── research.md                     # Phase 0: R1–R17
├── data-model.md                   # Phase 1: infrastructure entities, SSM layout, release state
├── quickstart.md                   # Phase 1: end-to-end validation
├── contracts/
│   ├── workspace-variables.md      # HCP workspace inputs/outputs, GitHub config
│   ├── host-interface.md           # rentsync-deploy, /healthz version, setup --deploy, public surface
│   └── bootstrap-iam.md            # Hand-created OIDC providers and roles
├── checklists/requirements.md
└── tasks.md                        # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
infra/
├── otel/collector.yaml             # endpoint parameterized (R8)
├── terraform/
│   ├── shared/                     # rentsync-shared-us: network, ecr, telemetry host, backup, budget
│   │   ├── versions.tf  main.tf  network.tf  ecr.tf  telemetry.tf  backup.tf  budget.tf
│   │   ├── variables.tf  outputs.tf
│   │   └── tests/*.tftest.hcl
│   ├── environment/                # rentsync-dev-staging + rentsync-prod-us (same code)
│   │   ├── versions.tf  main.tf  secrets.tf  variables.tf  outputs.tf
│   │   └── tests/*.tftest.hcl
│   ├── modules/host/               # instance, ENI, EIP, data volume, role, user data
│   │   ├── main.tf  iam.tf  variables.tf  outputs.tf
│   │   └── cloud-init.yaml.tftpl
│   └── check_prevent_destroy.sh    # static checks terraform test can't express
└── host/
    ├── compose.env.yaml            # environment host stack (R7)
    ├── compose.telemetry.yaml      # telemetry host stack
    ├── Caddyfile.env  Caddyfile.telemetry
    ├── daemon.json                 # Docker log rotation
    ├── bin/rentsync-boot  bin/rentsync-deploy  bin/rentsync-render-env  bin/rentsync-start
    ├── systemd/rentsync.service (boot as ExecStartPre)  rentsync-prune.{service,timer}  docker-rentsync.conf
    └── test/boot_volume_test.sh    # "format only if empty" on a loop device

mock_pms/
├── lib/mock_pms/api/ops.rb         # + version in /healthz
├── bin/setup                       # + --deploy
└── spec/...                        # failing specs first

.github/workflows/
├── ci.yml                          # + infra job (fmt, validate, test, shellcheck)
├── build-image.yml                 # reusable: arm64 build, push to ECR (skip if tag exists)
├── deploy-to.yml                   # reusable: SSM deploy + external /healthz check (URL from Environment SITE_URL)
├── release.yml                     # build arm64 → dev-staging → (approval) prod-us
└── deploy.yml                      # manual deploy / rollback

docs/
├── adr/0005-demo-aws-topology.md  0006-releases-via-ssm.md  0007-secrets-ssm-write-only.md
└── deploy/runbook.md  production-differences.md  iam/*.json (bootstrap policies)
```

**Structure Decision**:

- Infrastructure lives under `infra/`, next to the existing `infra/otel/`.
- Terraform code (`infra/terraform/`) is separate from what runs on the hosts (`infra/host/`).
  The host module reads the `infra/host/` files with `file()` and `templatefile()` into the
  cloud-init document, so each config file exists once.
- Operator documentation goes in `docs/deploy/`, and decisions in `docs/adr/`.

## Dependencies

Constitution VIII requires a one-line justification for each new dependency:

| Dependency | Justification |
|---|---|
| Terraform `hashicorp/aws` provider | The only way to declare the AWS resources the spec requires (FR-001). |
| Terraform `hashicorp/random` provider | Its `ephemeral "random_password"` generates database passwords without storing them in state (FR-024). |
| HCP Terraform | Required by the spec, for remote runs, approvals, sensitive variables and dynamic AWS credentials (FR-001 to FR-004). |
| Caddy 2 image | TLS termination with automatic Let's Encrypt issuance and renewal in a single binary (FR-014). |
| `aws-actions/configure-aws-credentials` | The standard GitHub OIDC-to-AWS role exchange, with no stored keys. |
| `aws-actions/amazon-ecr-login` | ECR registry login for the image push. |
| `docker/build-push-action` (+ `docker/setup-buildx-action`) | Reproducible image build and push, with layer caching to meet SC-005. |
| `hashicorp/setup-terraform` (CI) | Installs the pinned Terraform version for fmt, validate and test in CI (research R15). |
| `docker:27.5.1-dind` and `registry:2.8.3` images (local host rehearsal only, not CI) | `infra/host/test/rehearse/` runs the real host scripts and Compose stacks against real containers before any live apply, with a local registry standing in for ECR. |
| `xfsprogs` (CI runner, apt) | Provides `mkfs.xfs` for the loop-device test of `rentsync-boot`. It is the same tool the hosts use (research R6, R15). |
| Docker Compose v2 plugin (hosts, version pinned and checksum-verified) | Amazon Linux 2023 packages Docker but not the Compose plugin. Compose runs each host's stack (research R7). |
| `jq` (hosts, from the Amazon Linux 2023 repository) | `rentsync-deploy` parses `/healthz` JSON to check `status`, `version` and `deployment_id` (FR-028). |
| AWS CLI and the SSM Session Manager plugin (operator machine) | Shell access with no inbound port (FR-010). Not a project runtime dependency. |
| `nmap`, `gitleaks` (operator machine, optional) | Validation only: the port scan (SC-003) and the secret scan (SC-004). GitHub secret scanning covers the latter in CI. |

The existing images (Postgres 16, Redis 7, otel-collector-contrib, OpenObserve) are reused from
feature 001. No new Ruby gems are added.

## Blocked on the operator (hand-done steps)

Implementation can write and validate all the code. The following need the operator at a
console. Each one is a runbook step and a task gate:

1. The AWS OIDC providers and the two bootstrap roles
   ([contracts/bootstrap-iam.md](contracts/bootstrap-iam.md)).
2. The HCP project, workspaces, variable set, sensitive variables, VCS connection and remote
   state sharing.
3. The GitHub repository variables, the `dev-staging` and `prod-us` Environments, and the
   production reviewer.
4. The NameCheap A records, after the first applies.
5. Confirming the `rentsync-shared-us` and `rentsync-prod-us` applies, and approving the
   production deploy.

## Complexity Tracking

No Constitution Check violations. The single-host, single-VPC demo topology is mandated by the
spec and recorded as ADR 0005 together with its production differences. It is not a
constitution exception, because the service processes stay stateless (Principle X).
