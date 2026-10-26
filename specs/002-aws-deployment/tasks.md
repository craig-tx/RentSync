---

description: "Task list for feature 002: AWS Deployment of the Mock PMS"
---

# Tasks: AWS Deployment of the Mock PMS

**Input**: Design documents from `/specs/002-aws-deployment/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/workspace-variables.md](contracts/workspace-variables.md),
[contracts/host-interface.md](contracts/host-interface.md),
[contracts/bootstrap-iam.md](contracts/bootstrap-iam.md), [quickstart.md](quickstart.md)

**Tests**: These are **required**.

- Constitution Principle III requires test-first development for the feature 001 code changes
  (research R10).
- The plan (research R15) adds `terraform test`, `shellcheck`, and a loop-device test for the
  host scripts.
- In each phase, the test tasks come before the implementation they cover. Each test MUST be
  run and seen to fail before its implementation task starts.

**Organization**: Tasks are grouped by user story (US1–US5 from spec.md).

- Phase 2 holds the cross-cutting DeploymentId work (FR-038 to FR-042) and the Terraform and
  host foundation that every story builds on.
- Tasks marked **🧑 OPERATOR** need the operator at the AWS, HCP Terraform, GitHub, or
  NameCheap console, or need an approval click. An agent MUST NOT attempt them. It stops there,
  records the task as blocked in `docs/ai-build-log.md`, and continues with any remaining
  unblocked tasks.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: the task can run in parallel with other [P] tasks in the same phase. It touches
  different files and doesn't depend on unfinished tasks.
- **[Story]**: the user story the task belongs to.
- All paths are relative to the repository root.

## Conventions for every task

- **DeploymentId** (constitution v1.2.0, research R17):
  - It is validated with `^[a-z][a-z0-9-]{1,14}[a-z0-9]$`.
  - Every name a deployment owns derives from it:
    - resources and IAM roles: `rentsync-<id>-<thing>`;
    - SSM paths: `/rentsync/<id>/...`;
    - the database: `mock_pms_<id with _ for ->`;
    - the Compose project: `rentsync-<id>`.
  - **Never hard-code** a deployment-owned name, path, address, or ID. Take it from a variable,
    or from a `locals` value derived from `var.deployment_id`.
  - The first three IDs are `shared-us`, `dev-staging`, and `prod-us`.
- **Terraform**:
  - Terraform 1.16.x. `required_version = ">= 1.11"`, which the write-only arguments need.
  - `hashicorp/aws` ~> 6.x and `hashicorp/random` ~> 3.7, pinned exactly in
    `.terraform.lock.hcl`.
  - Every AWS provider block sets
    `default_tags { tags = { DeploymentId = var.deployment_id, Project = "rentsync", ManagedBy = "terraform" } }`.
  - Secrets use only `value_wo` and `value_wo_version`, never `value`, on `SecureString`
    parameters (R11). Secret variables are declared `sensitive = true` and `ephemeral = true`.
  - Run `terraform fmt` before every commit.
- **Shell** (`infra/host/bin/*`):
  - Bash, starting with `set -euo pipefail`. `set -x` is **forbidden**, because these scripts
    handle secrets.
  - The scripts must pass `shellcheck`.
  - Output is plain lines; no secret value is ever printed.
- **Ruby**: follow `specs/001-mock-pms/tasks.md` §Conventions (frozen string literals, the
  `MockPms::` namespace, logging through `Loggable`, RSpec in `mock_pms/spec/`).
- **Before every commit**:
  - run `docker compose exec mock_pms bundle exec rspec` and `rubocop`;
  - once the infra job exists (T004), also run `terraform fmt -check -recursive infra/terraform`,
    `terraform test` in both roots, and `shellcheck`.
- **Commits** are small and describe the change. The CLAUDE.md working rules apply.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the directory layout, provider pins, CI job, and document skeletons.

- [X] T001 Create the directory skeleton from plan.md §Project Structure:
  - `infra/terraform/shared/tests/`
  - `infra/terraform/environment/tests/`
  - `infra/terraform/modules/host/`
  - `infra/host/bin/`, `infra/host/systemd/`, `infra/host/test/`
  - `docs/deploy/iam/`

  Add `**/.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfplan`, and `crash.log` to `.gitignore`.
  Do not ignore `.terraform.lock.hcl`, which is committed.
- [X] T002 [P] Create `infra/terraform/shared/versions.tf`:
  - `terraform { required_version = ">= 1.11" ... }`;
  - `required_providers` for `aws` ~> 6.x and `random` ~> 3.7;
  - a `cloud` block with `organization = "craig-personal"` and
    `workspaces { project = "RentSync"  tags = ["rentsync-shared"] }`.

  Run `terraform init -backend=false`, then
  `terraform providers lock -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_arm64`.
  Commit `.terraform.lock.hcl`.
- [X] T003 [P] Create `infra/terraform/environment/versions.tf`. It is the same as T002, except
  the workspace tag is `tags = ["rentsync-environment"]`. Lock the providers the same way.
- [X] T004 Add an `infra` job to `.github/workflows/ci.yml`, alongside `test`, on
  `ubuntu-latest`. Its steps:
  1. `actions/checkout@v4`.
  2. `hashicorp/setup-terraform@v3` with `terraform_version: 1.16.x` and
     `terraform_wrapper: false`.
  3. `terraform fmt -check -recursive infra/terraform`.
  4. For each of `infra/terraform/shared` and `infra/terraform/environment`: `terraform init
     -backend=false`, `terraform validate`, and `terraform test`.
  5. `shellcheck infra/host/bin/* infra/host/test/*.sh`.
  6. `sudo bash infra/host/test/boot_volume_test.sh`.
  7. `bash infra/terraform/check_prevent_destroy.sh`.

  Steps that point at files that don't exist yet must not fail the job: guard them with
  `if [ -e ... ]`, and remove the guards in T076.
- [X] T005 [P] Check that the Dependencies table in `specs/002-aws-deployment/plan.md` has a
  justification line for every dependency introduced by this task list:
  `hashicorp/setup-terraform`, the Docker Compose v2 plugin, `jq` on the hosts, and each
  GitHub Action used in T060 and T061. Constitution VIII requires one for every dependency.
  Add any that are missing before using the dependency.
- [X] T006 [P] Create `docs/deploy/runbook.md`. Give it the headings listed below, in this order;
  each heading body is "TBD (task Txxx)" until filled in.
  - Bootstrap
  - DNS
  - First deploy
  - Release and promotion
  - Rollback
  - Host replacement
  - Backup restore
  - Secret rotation
  - Replaying failed webhooks on a deployed environment
  - Adding a side-by-side deployment
  - Teardown

  These cover FR-037, plus FR-042 for side-by-side deployments.
- [X] T007 [P] Create `docs/deploy/production-differences.md` with a table skeleton. Its columns
  are "Demo choice | Real production | Why the demo differs". There is one row per FR-036
  item, and the cells are filled in T084.

**Checkpoint**: CI has an `infra` job, and both Terraform roots initialize.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**:

- Bring the mock PMS into compliance with constitution v1.2.0 (`deployment.id`), and give it the
  health and setup behavior that deployment needs (research R10).
- Build the Terraform host module and both roots' DeploymentId plumbing.
- Write the host boot scripts.

**⚠️ CRITICAL**: No user story can start until this phase is complete.

### Tests for the mock PMS changes (write first; they must fail) ⚠️

- [X] T008 [P] Write `mock_pms/spec/unit/settings_spec.rb`, which tests three behaviors:
  - `MockPms::Settings.deployment_id` returns `ENV["DEPLOYMENT_ID"]`, and defaults to
    `"local-dev"` when the variable is unset;
  - it raises `ArgumentError` naming the variable for `"Prod_US"`, `"a"`, `"-x"`, `"x-"`, and
    any string longer than 16 characters;
  - it accepts `"prod-us"`, `"dev-staging"`, `"shared-us"`, and `"pr-42"`.

  The rule is `^[a-z][a-z0-9-]{1,14}[a-z0-9]$`.
- [X] T009 [P] Extend `mock_pms/spec/unit/logging_spec.rb`. Every emitted JSON line must contain
  `"deployment.id"` equal to `Settings.deployment_id`, next to the existing
  `"deployment.environment"`.
- [X] T010 [P] Create `mock_pms/spec/unit/metrics/exposition_spec.rb`. `Exposition.render`'s
  `target_info` line must include the label `deployment_id="<Settings.deployment_id>"`, next to
  the existing `deployment_environment`.
- [X] T011 [P] Extend `mock_pms/spec/requests/ops_spec.rb`:
  - `GET /healthz` returns `version` (= `Settings.service_version`) and `deployment_id`
    (= `Settings.deployment_id`), on both the 200 and the 503 bodies;
  - `GET /healthz/live` returns both fields;
  - the existing fields and status codes are unchanged (contracts/host-interface.md §/healthz).
- [X] T012 [P] Write `mock_pms/spec/integration/setup_deploy_spec.rb`. It runs
  `bin/setup --deploy` as a subprocess, with `DATABASE_URL` pointing at a scratch database
  `mock_pms_setup_deploy_spec` (dropped before and after) and **no** `TEST_DATABASE_URL` in the
  environment. Assert that:
  1. it exits 0, creates the database, and runs all migrations;
  2. it seeds when `operators` is empty, and prints `seeded=true`;
  3. after a client row is inserted, a second run prints `seeded=false` and the client still
     exists (FR-030);
  4. the test database is never touched.

  Before writing it, read `MockPms.ensure_database!` and `MockPms.boot!` in
  `mock_pms/lib/mock_pms/db.rb` and `mock_pms/lib/mock_pms.rb`, which commit 5160138 changed,
  and reuse them.

### Implementation for the mock PMS changes

- [X] T013 Implement `Settings.deployment_id` in `mock_pms/config/settings.rb`, with the
  validation from T008. Call it during `MockPms.boot!`, so an invalid value fails at startup.
  T008 must pass.
- [X] T014 [P] Add `"deployment.id" => Settings.deployment_id` to the base fields in
  `mock_pms/lib/mock_pms/logging.rb`, next to line 60. T009 must pass.
- [X] T015 [P] Add `"deployment_id" => Settings.deployment_id` to `target_info` in
  `mock_pms/lib/mock_pms/metrics/exposition.rb`, next to line 33. T010 must pass.
- [X] T016 [P] Add `version` and `deployment_id` to both bodies in
  `mock_pms/lib/mock_pms/api/ops.rb`. T011 must pass.
- [X] T017 Add a `--deploy` flag to `mock_pms/bin/setup`:
  - only `DATABASE_URL` is required;
  - it ensures the database exists and migrates it;
  - it seeds through `Seed::Reset.run!` only when `MockPms.db[:operators].empty?`;
  - it prints `setup complete (deploy; seeded=<true|false>)`.

  Without `--deploy`, the existing behavior is unchanged. T012 must pass.
- [X] T018 Update `infra/otel/collector.yaml`:
  - the exporter `endpoint` becomes `${env:OPENOBSERVE_OTLP_ENDPOINT}`;
  - in `file_log/docker`, add a `move` operator from `attributes["deployment.id"]` to
    `resource["deployment.id"]`;
  - in `transform/metrics_resource`, add
    `set(attributes["deployment.id"], attributes["deployment_id"]) where attributes["deployment_id"] != nil`
    and `delete_key(attributes, "deployment_id")`;
  - add a processor `resource/deployment` that `insert`s `deployment.environment` =
    `${env:DEPLOYMENT_ENVIRONMENT}` and `deployment.id` = `${env:DEPLOYMENT_ID}` (insert sets
    them only when missing), and add it to **both** pipelines after `memory_limiter`. Without it,
    the Collector's own metrics (the `otel-collector` scrape job) would carry neither attribute
    (constitution VI);
  - add `DEPLOYMENT_ENVIRONMENT` and `DEPLOYMENT_ID` to the Collector's environment in
    `compose.yaml`, which already loads them from `env_file: .env`.

  Update the file's header comment to mention research 002 R8.
- [X] T019 Update `.env.example`:
  - add `DEPLOYMENT_ID=local-dev` (with a comment pointing to constitution VI) and
    `OPENOBSERVE_OTLP_ENDPOINT=http://openobserve:5080/api/default`;
  - rename the databases to `.../mock_pms_local_dev` and `.../mock_pms_local_dev_test`.

  In `.github/workflows/ci.yml`, the `test` job gets `DEPLOYMENT_ID: ci-gh` (`ci` is too short for the format) and databases
  `mock_pms_ci_gh` and `mock_pms_ci_gh_test`. Grep `specs/001-mock-pms/quickstart.md`, `README.md`,
  and `mock_pms/` for hard-coded `mock_pms_test` or `/mock_pms"` and update them.

  Note in `docs/ai-build-log.md` that developers must re-copy `.env` from `.env.example`. The old
  `mock_pms` database is simply left unused.
- [X] T020 Extend `mock_pms/bin/telemetry_smoke`. It must also assert that at least one log
  record, one `mock_pms_*` metric, and one Collector self-metric (for example
  `otelcol_exporter_sent_log_records`) in OpenObserve carry `deployment.id` equal to
  `DEPLOYMENT_ID` and `deployment.environment` equal to `DEPLOYMENT_ENVIRONMENT`.
- [X] T021 [P] Add `version` (string) and `deployment_id` (string) to the `/healthz` and
  `/healthz/live` response schemas in `specs/001-mock-pms/contracts/openapi.yaml`, at lines
  729–745.
- [X] T022 Verify the changes so far:
  1. Re-copy `.env`, then `docker compose up -d --build` and
     `docker compose exec mock_pms bundle exec bin/setup`.
  2. Run the full `rspec` and `rubocop`.
  3. Run `docker compose exec mock_pms bundle exec bin/telemetry_smoke` after a scenario.

  Everything must pass. Commit as `feat(mock_pms): deployment.id, /healthz version, setup --deploy`.

### Tests for the Terraform and host foundation (write first; they must fail) ⚠️

- [X] T023 [P] Write `infra/terraform/environment/tests/deployment_id.tftest.hcl` using
  `mock_provider "aws" {}`, `mock_provider "random" {}`, and `override_data` for
  `terraform_remote_state.shared`. It needs these runs:
  - `invalid_id`: `deployment_id = "Prod_US"` →
    `expect_failures = [var.deployment_id]`;
  - `names_derive`: `deployment_id = "pr-42"` → assert
    - the instance `Name` tag is `rentsync-pr-42-host`;
    - the IAM role is named `rentsync-pr-42-host`;
    - every `aws_ssm_parameter` name starts with `/rentsync/pr-42/`;
    - `local.default_tags["DeploymentId"] == "pr-42"`. Mocked providers don't compute
      `tags_all`, so the real tags are proven live in T055;
  - `disjoint`: plan with `prod-us` and with `dev-staging`, and assert that the name sets
    don't intersect.
- [X] T024 [P] Write `infra/terraform/shared/tests/deployment_id.tftest.hcl` with the same
  pattern: an invalid ID fails, and with `deployment_id = "shared-us"` the VPC, subnet, and ECR
  names start with `rentsync-shared-us-` or `shared-us/`.
- [X] T025 [P] Write `infra/host/test/boot_volume_test.sh`. It creates a 64 MiB file, attaches
  it with `losetup`, and runs `infra/host/bin/rentsync-boot` with `RENTSYNC_DATA_DEVICE` set to
  the loop device and `RENTSYNC_DATA_MOUNT` set to a temporary directory. Then it checks:
  1. the volume gets formatted, mounted, and the `postgres/`, `caddy/`, `receiver/`,
     `openobserve/`, and `openobserve-db/` directories exist;
  2. after writing a sentinel file, unmounting, and running again, the sentinel **still exists**,
     so the volume was never reformatted (research R6).

  It exits non-zero on any failure, and cleans up with a trap.

### Implementation for the Terraform and host foundation

- [X] T026 Create `infra/terraform/modules/host/variables.tf` with these variables:

  | Variable | Type / default |
  |---|---|
  | `deployment_id` | string, validated by the regex |
  | `ami_id` | string |
  | `instance_type` | string |
  | `availability_zone` | string |
  | `subnet_id` | string |
  | `private_ip` | string |
  | `security_group_ids` | list(string) |
  | `user_data` | string, uncompressed cloud-init |
  | `root_volume_gib` | number, default 16 |
  | `data_volume_gib` | number, default 10 |
  | `data_snapshot_id` | string, default null |
  | `ssm_read_paths` | list(string), bare paths such as `/rentsync/<id>`, with no `/*` |
  | `ssm_write_params` | list(string) |
  | `ecr_repository_arn` | string |
  | `extra_tags` | map(string), default {} |

- [X] T027 Create `infra/terraform/modules/host/main.tf` with these resources:
  - `aws_network_interface.this`: `private_ips = [var.private_ip]`, the given security groups,
    and `Name = rentsync-<id>-eni`.
  - `aws_instance.this`:
    - the AMI and type, attached to the ENI as its primary interface (confirm the argument name
      for the pinned provider, per research R3);
    - `metadata_options { http_tokens = "required" }` and **no** `key_name`;
    - a gp3 root disk of `root_volume_gib`, encrypted, with
      `root_block_device { tags = { Name = "rentsync-<id>-root", DeploymentId = var.deployment_id, Project = "rentsync", ManagedBy = "terraform" } }`.
      Provider `default_tags` don't reach root volumes (constitution VI). Do **not** use
      `volume_tags`, which would fight the data volume's own tags;
    - `user_data_base64 = base64gzip(var.user_data)` and `user_data_replace_on_change = true`;
    - the instance profile, and tags `Name = rentsync-<id>-host` plus `extra_tags`.
  - `aws_eip.this` (`domain = "vpc"`), associated through `aws_eip_association` with the
    **ENI**, not the instance. `Name = rentsync-<id>-eip`.
  - `aws_ebs_volume.data`:
    - gp3, `data_volume_gib`, encrypted, `snapshot_id = var.data_snapshot_id`;
    - tags `Name = rentsync-<id>-data` and `rentsync:backup = daily`;
    - `lifecycle { prevent_destroy = true }`.
  - `aws_volume_attachment.data`: `device_name = "/dev/sdf"` and
    `stop_instance_before_detaching = true`.
- [X] T028 Create `infra/terraform/modules/host/iam.tf`:
  - role `rentsync-<id>-host`, with an EC2 trust policy and an instance profile of the same name;
  - attach `AmazonSSMManagedInstanceCore`;
  - an inline policy that grants:
    - `ecr:GetAuthorizationToken` on `*`;
    - `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, and
      `ecr:BatchCheckLayerAvailability` on `var.ecr_repository_arn`;
    - `ssm:GetParameter`, `ssm:GetParameters`, and `ssm:GetParametersByPath` on **both**
      `arn:…:parameter<path>` and `arn:…:parameter<path>/*` for each `var.ssm_read_paths`
      entry. `GetParametersByPath` is authorized against the path itself, so `/*` alone would
      deny `rentsync-render-env`;
    - `ssm:PutParameter` on each `var.ssm_write_params` ARN;
    - `kms:Decrypt` on `*`, with the condition `kms:ViaService = ssm.<region>.amazonaws.com`.
- [X] T029 Create `infra/terraform/modules/host/outputs.tf`, exposing `instance_id`, `public_ip`
  (the EIP), `private_ip`, `data_volume_id`, and `role_name`.
- [X] T030 Create `infra/terraform/modules/host/cloud-init.yaml.tftpl`. It takes `files`, a map
  from path to `{content, permissions}`, and `host_env`, a map of non-secret key/values. It must:
  1. write every file, plus `/etc/rentsync/host.env`, which contains `host_env` and
     `VOLUME_ID`;
  2. `dnf install -y docker jq`, then install the Docker Compose v2 plugin binary, with its
     version pinned as a template variable and its checksum verified;
  3. `systemctl enable --now docker rentsync-boot.service rentsync.service rentsync-prune.timer`.

  It contains no secrets (research R6).
- [X] T031 Write `infra/host/bin/rentsync-boot`. T025 must pass.
  1. Source `/etc/rentsync/host.env`.
  2. Resolve the device: use `RENTSYNC_DATA_DEVICE` if set (tests), otherwise
     `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}`. Wait up to 300 s for
     it to appear.
  3. Run `mkfs.xfs` **only if** `blkid` reports no filesystem.
  4. Add an fstab entry by UUID, with `nofail`, and mount it at `${RENTSYNC_DATA_MOUNT:-/srv/data}`.
  5. Create `postgres/`, `caddy/`, `receiver/`, `openobserve/`, and `openobserve-db/` on it.
  6. Install `infra/host/daemon.json` as `/etc/docker/daemon.json`. If it changed, restart
     Docker.
- [X] T032 [P] Create `infra/host/daemon.json` with
  `{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}` (FR-012).
- [X] T033 [P] Create the systemd units in `infra/host/systemd/`:
  - `rentsync-boot.service`: oneshot, `After=docker.service`, `RemainAfterExit=yes`;
  - `rentsync.service`: oneshot, `Requires=rentsync-boot.service`, runs
    `/usr/local/bin/rentsync-start`;
  - `rentsync-prune.service`: runs `docker image prune -af --filter until=168h`;
  - `rentsync-prune.timer`: weekly, `Persistent=true`.
- [X] T034 Write `infra/host/bin/rentsync-render-env`:
  - source `/etc/rentsync/host.env`;
  - call `aws ssm get-parameters-by-path --with-decryption --recursive` for each path in
    `SSM_READ_PATHS`;
  - write `/run/rentsync/env` atomically (temporary file, `chmod 600`, `mv`), mapping parameter
    leaf names to the variables in contracts/host-interface.md step 2;
  - append `host.env`'s non-secret keys;
  - build `DATABASE_URL` from `postgres_password` and `DB_NAME`;
  - set `COMPOSE_PROJECT_NAME=rentsync-${DEPLOYMENT_ID}`.

  It never prints values, and must pass `shellcheck`.
- [X] T035 [P] Write `infra/host/bin/rentsync-start`, which `rentsync.service` runs:
  - if `HOST_ROLE=environment`, it runs `rentsync-deploy --reload`;
  - if `HOST_ROLE=telemetry`, it runs `rentsync-render-env`, then
    `docker compose -f /opt/rentsync/compose.yaml up -d`.
- [X] T036 Create `infra/terraform/environment/main.tf`:
  - `locals`:
    - `name = "rentsync-${var.deployment_id}"`;
    - `ssm_prefix = "/rentsync/${var.deployment_id}"`;
    - `db_name = "mock_pms_${replace(var.deployment_id, "-", "_")}"`;
    - `default_tags = { DeploymentId = var.deployment_id, Project = "rentsync", ManagedBy = "terraform" }`;
  - `provider "aws"` with `region` and `default_tags { tags = local.default_tags }`;
  - `data "terraform_remote_state" "shared"`, using backend `remote` with
    `organization = "craig-personal"` and `workspaces = { name = var.shared_workspace }`.

  Also create `infra/terraform/environment/variables.tf` with every variable in
  contracts/workspace-variables.md §`rentsync-dev-staging` / `rentsync-prod-us`. Apply these
  rules:
  - `deployment_id` is validated by the regex;
  - `environment` is validated to `staging` or `production`;
  - `admin_token` is `sensitive` and `ephemeral`, with `validation` that its length is ≥ 32 and
    it is not `"change-me-admin-token"`;
  - `shared_workspace` defaults to `"rentsync-shared-us"`.
- [X] T037 Create `infra/terraform/shared/main.tf` with
  `locals { name = "rentsync-${var.deployment_id}", ssm_prefix = "/rentsync/${var.deployment_id}", default_tags = { ... as T036 } }`
  and the provider with `default_tags { tags = local.default_tags }`.
  Create `infra/terraform/shared/variables.tf` with every variable in
  contracts/workspace-variables.md §`rentsync-shared-us`. Apply these rules:
  - `deployment_id` is validated by the regex;
  - `openobserve_root_password` is `sensitive = true` and `ephemeral = true`, and validated to
    8–128 characters;
  - `budget_email` and `acme_email` have no default.
- [X] T038 Create `infra/terraform/check_prevent_destroy.sh`, which runs static checks that
  `terraform test` cannot express. It fails unless all of the following hold:
  1. the `aws_ebs_volume` `data` block in `infra/terraform/modules/host/main.tf` contains
     `prevent_destroy = true` (FR-034);
  2. the `root_block_device` block there contains `tags` (constitution VI);
  3. no `aws_ssm_parameter` block anywhere under `infra/terraform/` with
     `type = "SecureString"` contains a `value =` argument; only `value_wo` is allowed (R11).

  Make it executable with `git update-index --chmod=+x`.

**Checkpoint**:
- The mock PMS emits `deployment.id` and passes all specs.
- T025 passes. T038 passes for the files that exist so far.
- T023 and T024 are written and **fail**, because the resources they test come in US1. They
  pass at T046 (shared) and T049 (environment).
- `terraform validate` passes in both roots.

---

## Phase 3: User Story 1 - Provision both environments and shared telemetry from code (Priority: P1) 🎯 MVP

**Goal**: An apply in each of the three workspaces creates one VPC and three hosts (`shared-us`,
`dev-staging`, `prod-us`). Each host has an Elastic IP and a data volume. The only public ports
are 80 and 443, and no long-lived AWS key exists anywhere.

**Independent Test**: [quickstart.md](quickstart.md) §1–§2:
- three hosts with stable public IPs;
- `nmap` finds only 80 and 443;
- `aws ssm start-session` works;
- no secret appears in state or in run logs;
- every resource carries `DeploymentId`.

### Tests for User Story 1 (write first; they must fail) ⚠️

- [X] T039 [P] [US1] Write `infra/terraform/environment/tests/security.tftest.hcl` with mocked
  providers. Its assertions:
  - the deployment security group has ingress **only** on TCP 80 and 443 from `0.0.0.0/0`, and
    no rule on port 22 (FR-009);
  - the instance has `metadata_options.http_tokens == "required"` and a null `key_name`;
  - the data volume is `encrypted`;
  - every `SecureString` `aws_ssm_parameter` has `value_wo_version` set to its `*_version`
    variable. `value` is unknown at plan time under mocks, so the "no `value =`" rule lives in
    T038's static check (R11);
  - the `admin_token` cases `"change-me-admin-token"` and a 31-character string both hit
    `expect_failures = [var.admin_token]` (FR-025).
- [X] T040 [P] [US1] Write `infra/terraform/shared/tests/security.tftest.hcl` with mocked
  providers. Its assertions:
  - the telemetry security group allows TCP 80 and 443 from `0.0.0.0/0`, and TCP 5080 **only**
    with `referenced_security_group_id` = the `otlp-client` group, never a CIDR (FR-011);
  - there is no port 22;
  - the budget `rentsync-shared-us-monthly` has a limit equal to `var.budget_limit_usd`, and
    notifications for ACTUAL 80%, ACTUAL 100%, and FORECASTED 100% (FR-035);
  - the ECR repository has `image_tag_mutability = "IMMUTABLE"` and `scan_on_push = true`.

### Implementation for User Story 1

- [X] T041 [US1] Create `infra/terraform/shared/network.tf`:
  - `aws_vpc` `${local.name}-vpc` (`var.vpc_cidr`, DNS hostnames on);
  - `aws_subnet` `${local.name}-subnet` (`var.subnet_cidr`, `var.availability_zone`);
  - `aws_internet_gateway` `${local.name}-igw`;
  - `aws_route_table` `${local.name}-rt` with `0.0.0.0/0` to the IGW, and its association.
- [X] T042 [P] [US1] Create `infra/terraform/shared/ecr.tf`:
  - `aws_ecr_repository` named `"${var.deployment_id}/mock_pms"`, with `IMMUTABLE` tags,
    `scan_on_push = true`, and `force_delete = false`;
  - `aws_ecr_lifecycle_policy` that keeps the last 100 images (R16; raised from 20 so prod-us's image and its rollback target never expire).
- [X] T043 [US1] Create `infra/terraform/shared/telemetry.tf`:
  - security groups use standalone `aws_vpc_security_group_ingress_rule` and `aws_vpc_security_group_egress_rule` resources, never inline `ingress`/`egress` blocks (T040 relies on `referenced_security_group_id`);
  - `aws_security_group` `${local.name}-otlp-client` (no ingress, all egress);
  - `aws_security_group` `${local.name}-sg`: 80 and 443 from anywhere, 5080 from the otlp-client
    group, all egress;
  - `module "telemetry_host"` (`../modules/host`):
    - `private_ip = var.telemetry_private_ip`;
    - `ssm_read_paths = [local.ssm_prefix]` and `ssm_write_params = []`;
    - `extra_tags = {}` (not deployable);
    - user data from the cloud-init template, with only the Phase 2 base files for now. US3
      adds the stack.
- [X] T044 [US1] Create `infra/terraform/shared/secrets.tf`:
  - `String` parameters `${local.ssm_prefix}/openobserve/root_email` and `.../ingest/user`
    (both `var.openobserve_root_email`);
  - `SecureString` `.../openobserve/root_password` and `.../openobserve/ingest/password`, both
    `value_wo = var.openobserve_root_password` and
    `value_wo_version = var.openobserve_root_password_version`;
  - `ephemeral "random_password" "openobserve_db"` (32 characters, `special = false`) written to
    `.../openobserve/db_password` with `value_wo_version = var.openobserve_db_password_version`.
- [X] T045 [P] [US1] Create `infra/terraform/shared/budget.tf`: `aws_budgets_budget`
  `${local.name}-monthly`, of type COST, with a monthly limit of `var.budget_limit_usd` USD and
  the three notifications to `var.budget_email` (FR-035).
- [X] T046 [US1] Create `infra/terraform/shared/outputs.tf` with every output in
  contracts/workspace-variables.md:
  - `vpc_id`, `subnet_id`, and `otlp_client_security_group_id`;
  - `availability_zone` and `ami_id`;
  - `ecr_repository_url` and `ecr_repository_arn`;
  - `otlp_endpoint = "http://${var.telemetry_private_ip}:5080/api/default"`;
  - `telemetry_public_ip`;
  - `ingest_ssm_path = "${local.ssm_prefix}/openobserve/ingest"`.

  T024 and T040 must pass.
- [X] T047 [US1] Create `infra/terraform/environment/outputs.tf` with `public_ip`,
  `instance_id`, and `url = "https://${var.hostname}"`. The variables already exist (T036).
- [X] T048 [US1] Add the security group and host to `infra/terraform/environment/main.tf`:
  - `aws_security_group` `${local.name}-sg`, with standalone rule resources as in T043: 80 and 443 from anywhere, all egress, in the shared
    VPC;
  - `module "host"`:
    - `security_group_ids = [sg, shared.otlp_client_security_group_id]`;
    - `ssm_read_paths = [local.ssm_prefix, shared.ingest_ssm_path]`;
    - `ssm_write_params` = the `image_tag` and `previous_image_tag` parameter ARNs;
    - `extra_tags = { "rentsync:deployable" = "true" }`;
    - `data_snapshot_id = var.data_snapshot_id`;
    - user data with the Phase 2 base files, and `host_env` containing `HOST_ROLE=environment`,
      `DEPLOYMENT_ID`, `DEPLOYMENT_ENVIRONMENT`, `SITE_HOSTNAME`, `DB_NAME`, `AWS_REGION`,
      `SSM_READ_PATHS`, `ECR_REPOSITORY_URL`, and `OPENOBSERVE_OTLP_ENDPOINT`.
- [X] T049 [US1] Create `infra/terraform/environment/secrets.tf`:
  - `SecureString` `${local.ssm_prefix}/admin_token`, with `value_wo = var.admin_token` and
    `value_wo_version = var.admin_token_version`;
  - `ephemeral "random_password" "postgres"` (32 characters, `special = false`) written to
    `${local.ssm_prefix}/postgres_password`, with `value_wo_version = var.postgres_password_version`;
  - `String` parameters `${local.ssm_prefix}/image_tag` and `.../previous_image_tag`, with
    `value = "none"` and `lifecycle { ignore_changes = [value] }`.

  T023 and T039 must pass. Commit.
- [X] T050 [P] [US1] Write the IAM policy documents from contracts/bootstrap-iam.md, as valid
  JSON with an `<aws-account-id>` placeholder:
  - `docs/deploy/iam/hcp-terraform-trust.json` and `hcp-terraform-policy.json`;
  - `docs/deploy/iam/github-actions-trust.json` and `github-actions-policy.json`.

  Validate each with `jq . file`.
- [X] T051 [US1] Fill in runbook §Bootstrap in `docs/deploy/runbook.md` (FR-006, under one
  hour). Give numbered console click paths for:
  1. the two IAM OIDC providers;
  2. the roles `rentsync-hcp-terraform` and `rentsync-github-actions`, pasting the T050 JSON;
  3. the HCP project `RentSync`, and the variable set `rentsync-aws` from
     contracts/workspace-variables.md;
  4. the workspaces `rentsync-shared-us` (working directory `infra/terraform/shared`, auto-apply
     off), `rentsync-dev-staging` (`infra/terraform/environment`, auto-apply on), and
     `rentsync-prod-us` (`infra/terraform/environment`, auto-apply off). For each: the VCS
     connection to `craig-tx/RentSync` on `main`, the Terraform version 1.16.x, and health
     assessments on;
  5. remote state sharing from `rentsync-shared-us` to the two environment workspaces;
  6. every workspace variable, with `openssl rand -hex 32` for each `admin_token`;
  7. the GitHub variables `AWS_ROLE_ARN`, `AWS_REGION`, and `ECR_REPOSITORY_URL`, and the
     Environments `dev-staging` and `prod-us`. Each Environment gets an Environment variable
     `SITE_URL`: `https://pms-staging.rentsync.org` and `https://pms.rentsync.org`. That is the
     only place deployment URLs are recorded;
  8. activating the `DeploymentId` cost allocation tag.

  End with a table of every non-secret value (AWS account ID, AWS region, HCP Terraform organization, AWS IAM role ARNs) and
  where each is entered. **Never** ask for a credential in chat.
- [X] T052 [US1] Fill in runbook §DNS:
  - the three NameCheap A records (`telemetry`, `pms-staging`, `pms`), with the output each one
    takes its value from (data-model.md §DNS record);
  - TTL of 5 minutes during bring-up;
  - verification with `dig +short`;
  - switching `acme_ca` from Let's Encrypt staging to production after DNS resolves.
- [X] T052a [US1] Script runbook §Bootstrap steps 1–2 in `infra/bootstrap/bootstrap-iam.sh`, for
  AWS CloudShell (no access keys). It renders the `iam/` files into the gitignored
  `.bootstrap/iam/`, validates them with Access Analyzer, prints a plan, and applies only with
  `--apply`. It is idempotent. (`--render-only`, which served the console path, was removed with that path.) Test with a
  stub `aws`: `infra/bootstrap/test/bootstrap_iam_test.sh`, run in CI.
- [X] T052b [US1] Script runbook §Bootstrap steps 4–6 in `infra/bootstrap/bootstrap-hcp.rb`
  (Ruby standard library only), through the HCP Terraform API: the project, the variable set,
  the workspaces, remote state sharing and the variables. It generates each `admin_token`,
  prompts for the OpenObserve password without echo, prints a plan unless `--apply` is given,
  restores drifted workspace settings, and never changes a variable that exists. Test against a
  fake API: `infra/bootstrap/test/bootstrap_hcp_test.rb`, run in CI.
- [X] T052c [US1] Script the GitHub part of runbook §Bootstrap in `infra/bootstrap/bootstrap-github.sh`,
  through the GitHub API (`gh`): the repository variables, both Environments restricted to
  `main`, their variables, and secret scanning and push protection, plus `--ecr-repository-url`
  (after T054) and `--prod-reviewer` (T074). It plans by default, is idempotent, and keeps
  existing reviewers. Test with a stub `gh`: `infra/bootstrap/test/bootstrap_github_test.sh`,
  run in CI.
- [X] T052d [US1] Make runbook §Bootstrap script-only: five steps (IAM script, AMI lookup, HCP
  script, GitHub script, cost allocation tag by AWS CLI), with no console click paths. Remove
  `bootstrap-iam.sh --render-only`, and reword spec.md (Bootstrap), contracts/bootstrap-iam.md
  and quickstart §1 to match.
- [X] T052e [US1] Make the deployment operator-neutral (spec Session 2026-10-25): `bootstrap-init.sh`
  asks for the deployment settings and writes the gitignored `.bootstrap/settings.env`, which
  every bootstrap script reads. IAM documents become templates (`<aws-region>`,
  `<hcp-organization>`, `<github-subject>`, read from GitHub), Terraform loses its region, zone,
  hostname and organization defaults (`TF_CLOUD_ORGANIZATION`, `hcp_organization`), and the
  runbook, contracts and quickstart use `<domain>` and `$RENTSYNC_…`. Proven against the
  reference deployment: the IAM render is byte-identical, and the HCP plan only adds the new
  variables. Test: `infra/bootstrap/test/bootstrap_init_test.sh`, run in CI.
- [X] T052f [US1] Give every bootstrap script a `--teardown` mode (constitution v1.4.0, Reversible
  bootstrap). Each lists what it will delete, warns, and deletes only after a correct answer to a
  sum typed at an interactive terminal. IAM: the four roles and policies by exact name, the
  providers the bootstrap created (now tagged `rentsync:bootstrap=true`), and the cost allocation
  tag. It refuses while tagged instances or volumes exist. HCP Terraform: the workspaces (safe
  delete; refuses while one manages resources), the variable set, and the project unless it
  holds other workspaces. GitHub: the variables and Environments. Secret scanning, adopted
  providers, the HCP Terraform GitHub connection and the settings file are kept and reported.
  Runbook §Bootstrap teardown. Tests drive the shell confirmations through script(1).
- [X] T052g [US1] Make runbook §Bootstrap work the same on macOS and Windows: OS-neutral steps
  and commands, a macOS setup (`brew install bash ruby gh hashicorp/tap/terraform`) and one
  Windows note (Git Bash, not WSL; PowerShell for `bootstrap-hcp.rb`). Require bash 4.4+ and
  Ruby 3+. The bash scripts refuse older bash (macOS ships 3.2) with the fix, checked in CI
  under bash 3.2, 4.3 and 4.4.
- [X] T052h [US1] One VPC per deployment (spec Session 2026-10-25, FR-007, FR-011; ADR-0008).
  `modules/network` gives each deployment its VPC, subnet, gateway and route table, with standalone
  routes only. Each environment peers only with the shared VPC, adds its return route and its OTLP
  rule (5080 from its subnet) from its own state, and stays in the shared zone. The `otlp-client`
  group is gone. Ranges: shared `10.40.0.0/16`, staging `10.41.0.0/16`, prod `10.42.0.0/16`.
  `check_prevent_destroy.sh` forbids inline route, ingress and egress blocks. Docs name the
  production gold standard: the Multi-Account Strategy via AWS Organizations.
- [X] T052i [US1] Hardening from review:
  - **mock_pms image:** multi-stage. The production target holds runtime gems only (no test or
    dev gems, no compiler) and runs as UID 10001; local Compose uses the `dev` target. The
    host chowns `/srv/data/receiver` to UID 10001.
  - **Supply chain:** Dependabot for gems, Actions, Docker and Terraform; every Action pinned
    to a commit SHA.
  - **CI scanning:** `bundle-audit`, CodeQL (Ruby), and Trivy for Terraform, with accepted
    findings in `infra/terraform/.trivyignore`.
  - **Audit logging:** a CloudTrail trail (all regions, log file validation) and VPC Flow Logs
    for every deployment, into one private, encrypted log bucket kept 90 days, with the HCP
    Terraform role permissions to manage them.
  - **Docs:** runbook §Monthly OS patching and §Audit logs; production-differences adds a
    security section (CSPM such as Orca, GuardDuty, Security Hub, Config, log archive, egress,
    patching, scanning).

> **Merge order changed (operator decision, 2026-10-25):** the branch merges to `main` before
> the live checks, at T090–T091. The HCP Terraform workspaces track `main`, and the
> `rentsync-github-build` role trusts only `refs/heads/main`, so nothing can be applied or built
> from the feature branch. The operator and live-check tasks below (T053–T055, T064–T065,
> T070–T071, T074–T075, T082–T083, T089) run against `main` after the merge. Any fixes they
> need go in follow-up PRs, and their results go in `docs/ai-build-log.md` (T091a).

- [ ] T053 [US1] **🧑 OPERATOR**: perform runbook §Bootstrap. Record the elapsed time in
  `docs/ai-build-log.md`, against FR-006's one-hour limit.
- [ ] T054 [US1] **🧑 OPERATOR** (runbook §First apply): apply `rentsync-shared-us` (confirm), then
  `rentsync-dev-staging`, then `rentsync-prod-us` (confirm), with `acme_ca` set to the Let's
  Encrypt staging endpoint. Then rerun `bootstrap-github.sh` with `--ecr-repository-url` (runbook §Bootstrap step 3), and add the A records (runbook §DNS; the workspace outputs
  are the record of the IPs). Record the elapsed time from the first apply to three hosts
  serving HTTPS, excluding DNS propagation, in `docs/ai-build-log.md`, against SC-001's 60
  minutes.
- [ ] T055 [US1] Run quickstart §2 and §9a's tag audit:
  - `nmap` against each IP;
  - `aws ssm start-session`;
  - search the downloaded state for each admin token;
  - `aws resourcegroupstaggingapi` to find untagged resources, root volumes included;
  - download each HCP run's plan and apply logs and search them for each admin token and the
    OpenObserve password (SC-004);
  - `chronyc tracking` on each host, which should show a synchronized source (FR-012).

  Record the results in `docs/ai-build-log.md`. Stop and log any failure.

**Checkpoint**: three reachable hosts, with only 80 and 443 open and every resource tagged.

---

## Phase 4: User Story 2 - The mock PMS works end to end on staging and production (Priority: P1)

**Goal**: The full feature 001 stack runs behind Caddy and HTTPS at `pms-staging.rentsync.org`
(`dev-staging`) and `pms.rentsync.org` (`prod-us`), deployed by `rentsync-deploy`.

**Independent Test**: [quickstart.md](quickstart.md) §4. The feature 001 quickstart §3–§9 pass
on both deployments: the public checks from a laptop, the on-host checks in an SSM session. One
public webhook verifies, and a client from one deployment doesn't exist on the other.

### Implementation for User Story 2

- [X] T056 [P] [US2] Create `infra/host/compose.env.yaml` per research R7:
  - services `caddy`, `mock_pms`, `mock_pms_worker`, `postgres`, `redis`, `otel-collector`, and
    `receiver` (profile `tools`);
  - the image is `${MOCK_PMS_IMAGE}`; there is no `build:`;
  - `env_file: /run/rentsync/env`;
  - Postgres data at `/srv/data/postgres`, Caddy at `/srv/data/caddy:/data`, and receiver logs at
    `/srv/data/receiver`;
  - `restart: unless-stopped` everywhere;
  - `stop_grace_period: 30s` on the worker;
  - the Collector mounts `/opt/rentsync/collector.yaml` and `/var/lib/docker/containers:ro`;
  - only Caddy publishes ports (`80:80`, `443:443`).

  The service names must equal the local `compose.yaml` names, so the Collector scrape target
  `mock_pms:4001` and the 001 tools keep working.
- [X] T057 [P] [US2] Create `infra/host/Caddyfile.env`:
  - a global block with `email {$ACME_EMAIL}` and `acme_ca {$ACME_CA}`;
  - a site `{$SITE_HOSTNAME}` with `respond /metrics 404` and `reverse_proxy mock_pms:4001`.

  Caddy redirects HTTP to HTTPS automatically (FR-014).
- [X] T058 [US2] Write `infra/host/bin/rentsync-deploy` to the exact behavior and exit codes in
  contracts/host-interface.md §rentsync-deploy:
  - `flock` with a 10-minute wait, exiting 75;
  - `rentsync-render-env`;
  - the already-running no-op;
  - ECR login and pull;
  - `docker compose run --rm mock_pms bundle exec bin/setup --deploy`;
  - `up -d --remove-orphans`;
  - the health poll, every 3 s for up to 120 s, checking `status`, `version`, and
    `deployment_id`;
  - on success, a `put-parameter --overwrite` of `previous_image_tag`, then `image_tag`;
  - on failure, a rollback to the old tag, exiting 1, or exiting 2 if that also fails;
  - `--rollback` and `--reload`. `--reload` with `image_tag = none` only starts Caddy, and prints
    `no image deployed yet`.

  It must pass `shellcheck`.
- [X] T059 [US2] Wire the US2 files into `infra/terraform/environment/main.tf`'s cloud-init
  `files`, read with `file("${path.module}/../../host/...")`:
  - `compose.env.yaml` → `/opt/rentsync/compose.yaml`;
  - `Caddyfile.env` → `/opt/rentsync/Caddyfile`;
  - `infra/otel/collector.yaml` → `/opt/rentsync/collector.yaml`;
  - `rentsync-deploy`, `rentsync-render-env`, `rentsync-start`, and `rentsync-boot` →
    `/usr/local/bin/`, mode 0755;
  - the systemd units;
  - `daemon.json`.

  Add `ACME_EMAIL` and `ACME_CA` to `host_env`. Re-run the terraform tests.
- [X] T060 [P] [US2] Create `.github/workflows/build-image.yml`, a reusable workflow (`on:
  workflow_call`) that takes the input `sha` and runs on `ubuntu-24.04-arm` with
  `permissions: id-token: write, contents: read`. Its steps:
  1. `aws-actions/configure-aws-credentials@v4` with `vars.AWS_ROLE_ARN`;
  2. `aws-actions/amazon-ecr-login@v2`;
  3. skip the remaining steps if `aws ecr describe-images --image-ids imageTag=<sha>` succeeds;
  4. `docker/setup-buildx-action@v3`, then `docker/build-push-action@v6` with
     `context: mock_pms`, `platforms: linux/arm64`, `build-args: GIT_SHA=<sha>`,
     `tags: ${{ vars.ECR_REPOSITORY_URL }}:<sha>`, and the GitHub Actions cache.
- [X] T061 [P] [US2] Create `.github/workflows/deploy-to.yml`, a reusable workflow that takes
  the inputs `deployment_id`, `image_tag`, and `rollback` (bool). The URL comes from the
  Environment variable `vars.SITE_URL`, never from an input. Its job:
  - uses `environment: ${{ inputs.deployment_id }}` and `concurrency: deploy-${{ inputs.deployment_id }}`;
  - assumes the role through OIDC;
  - runs `aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:DeploymentId,Values=<id>`
    with the command `/usr/local/bin/rentsync-deploy <tag|--rollback>`, and a 15-minute timeout;
  - waits with `aws ssm wait command-executed`, prints the stdout and stderr from
    `get-command-invocation`, and fails if the status is not `Success`;
  - then runs `curl -fsS ${{ vars.SITE_URL }}/healthz | jq`, asserting `status=="ok"` and
    `deployment_id==<id>`, and also `version==<tag>` when not rolling back.
- [X] T062 [US2] Create `.github/workflows/deploy.yml` (`on: workflow_dispatch`). Its inputs are
  `deployment_id` (choice: `dev-staging` or `prod-us`), `image_tag` (string, optional), and
  `rollback` (boolean). It:
  - calls `build-image.yml` when an `image_tag` is given and missing;
  - calls `deploy-to.yml`.

  This is the documented single action for manual deploys and rollback (FR-029).
- [X] T063 [US2] Fill in runbook §First deploy:
  1. apply the US2 Terraform change (hosts are replaced; data volumes are still empty);
  2. run `deploy.yml` with `deployment_id=dev-staging` and the `main` SHA;
  3. check `/healthz`;
  4. repeat for `prod-us`.

  Also fill in runbook §Replaying failed webhooks on a deployed environment: the 001
  `POST /admin/events/{evt}/replay` and `POST /admin/replays` calls against `$BASE`, with that
  deployment's `ADMIN_TOKEN` read through `aws ssm get-parameter --with-decryption` in the
  operator's own shell.
- [ ] T064 [US2] **🧑 OPERATOR**:
  1. Once DNS resolves, switch `acme_ca` to Let's Encrypt production in all three workspaces,
     and apply `rentsync-dev-staging`, then `rentsync-prod-us` (confirm), with the US2 files.
     Do this **before** the first deploy: the hosts hold no data yet, so the replacement is
     free, and `deploy-to.yml`'s external check verifies the certificate, which a staging-CA
     certificate fails.
  2. Run `deploy.yml` for `dev-staging`, then `prod-us` (approve).
- [ ] T065 [US2] Run quickstart §3 (the certificate, the HTTP→HTTPS 308, `/metrics` 404) and §4
  in full on `dev-staging`, then on `prod-us`. Record each 001 section's result per deployment in
  `docs/ai-build-log.md`, and reset chaos rates to 0 afterwards.

**Checkpoint**: both deployments pass every feature 001 check.

---

## Phase 5: User Story 3 - See both environments' telemetry in one place (Priority: P2)

**Goal**: OpenObserve at `https://telemetry.rentsync.org` (behind sign-in) shows logs and
metrics from both deployments, filterable by `deployment.environment` and `deployment.id`.
Ingest stays inside the VPC.

**Independent Test**: [quickstart.md](quickstart.md) §5:
- a scenario on each deployment is visible within 60 s and filterable apart;
- a correlation ID search shows web and worker lines together;
- an anonymous visitor sees only the sign-in page;
- with OpenObserve stopped, the PMS keeps working.

### Implementation for User Story 3

- [X] T066 [P] [US3] Create `infra/host/compose.telemetry.yaml` per research R7:
  - `caddy` (ports 80 and 443, data in `/srv/data/caddy`);
  - `openobserve` (`openobserve/openobserve:v1.0.4`), with `ZO_ROOT_USER_EMAIL` and
    `ZO_ROOT_USER_PASSWORD` from the env file, `ZO_DATA_DIR=/data` mounted from
    `/srv/data/openobserve`, `ZO_META_STORE=postgres`, and
    `ZO_META_POSTGRES_DSN=postgres://openobserve:${OPENOBSERVE_DB_PASSWORD}@openobserve-db:5432/${DB_NAME}`.
    It publishes `${PRIVATE_IP}:5080:5080`, on the private IP **only**;
  - `openobserve-db` (`postgres:16`), with data in `/srv/data/openobserve-db` and
    `POSTGRES_USER=openobserve`;
  - `restart: unless-stopped` everywhere.

  First confirm that the v1.0.4 image has an arm64 variant (research R4). If it doesn't, set
  `telemetry_instance_type = "t3.small"` and log the change.
- [X] T067 [P] [US3] Create `infra/host/Caddyfile.telemetry`: the same global block as T057, and
  a site `{$SITE_HOSTNAME}` with `reverse_proxy openobserve:5080`.
- [X] T068 [US3] Extend `infra/host/bin/rentsync-render-env` for `HOST_ROLE=telemetry`. It maps
  `openobserve/root_email`, `root_password`, and `db_password` to `ZO_ROOT_USER_EMAIL`,
  `ZO_ROOT_USER_PASSWORD`, and `OPENOBSERVE_DB_PASSWORD`. For `HOST_ROLE=environment`, it maps
  `ingest/user` and `ingest/password` to `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD`.
  It must pass `shellcheck`.
- [X] T069 [US3] Wire the telemetry files into `infra/terraform/shared/telemetry.tf`'s
  cloud-init:
  - `compose.telemetry.yaml` → `/opt/rentsync/compose.yaml`;
  - `Caddyfile.telemetry` → `/opt/rentsync/Caddyfile`;
  - the scripts, units, and `daemon.json`;
  - `host_env` with `HOST_ROLE=telemetry`, `DEPLOYMENT_ID`, `SITE_HOSTNAME = var.telemetry_hostname`,
    `PRIVATE_IP`, `DB_NAME = "openobserve_${replace(var.deployment_id, "-", "_")}"`, `ACME_*`,
    `AWS_REGION`, and `SSM_READ_PATHS`.

  Re-run the terraform tests.
- [ ] T070 [US3] **🧑 OPERATOR**: apply `rentsync-shared-us` (confirm; this replaces the
  telemetry host). Sign in to `https://telemetry.rentsync.org` once.
- [ ] T071 [US3] Run quickstart §5 and record the results in `docs/ai-build-log.md`:
  - the `deployment.environment` and `deployment.id` filters;
  - the correlation ID search;
  - the anonymous visit;
  - the OpenObserve stop and start test;
  - SC-008 timing.

**Checkpoint**: one telemetry UI shows both deployments, separated.

---

## Phase 6: User Story 4 - Release a new version to staging, then production (Priority: P2)

**Goal**:
- A green `main` builds one image and deploys it to `dev-staging`.
- An approved promotion deploys the same image to `prod-us`.
- A failed health check rolls back automatically.
- Rollback takes one action.

**Independent Test**: [quickstart.md](quickstart.md) §3 (promotion) and §6:
- staging moves first while production stays on the old version;
- approving moves production to the same SHA;
- a rollback restores N−1 with its data intact;
- a broken image is rolled back automatically.

### Implementation for User Story 4

- [X] T072 [US4] Create `.github/workflows/release.yml`:
  - triggers on `workflow_run` for `workflows: [CI]`, `types: [completed]`, `branches: [main]`,
    and runs only when `github.event.workflow_run.conclusion == 'success'`;
  - its jobs:
    1. `build`, which uses `build-image.yml` with `sha = github.event.workflow_run.head_sha`;
    2. `deploy-dev-staging`, which uses `deploy-to.yml` with `deployment_id: dev-staging`;
    3. `deploy-prod-us`, which uses `deploy-to.yml` with `deployment_id: prod-us`, and
       `needs: deploy-dev-staging`. Its approval gate is the `prod-us` Environment reviewer.

    The URLs come from each Environment's `SITE_URL` (T051).
  - Both deploy jobs pass the **same** SHA. Nothing is rebuilt (FR-027).
- [X] T073 [US4] Fill in runbook §Release and promotion and §Rollback:
  - the merge → staging → approve → production flow;
  - where to watch it;
  - what a self-rollback looks like (`rolled back to <old>`, a red workflow);
  - the one rollback action, `deploy.yml` with `rollback=true`;
  - the **expand-only migrations** rule: a release may add tables and columns, never drop or
    rename them. Contraction happens a release later (research R9).
- [ ] T074 [US4] **🧑 OPERATOR**: rerun `bootstrap-github.sh` with `--prod-reviewer <your GitHub
  username>` (runbook §Bootstrap step 3). It adds you as the `prod-us` required reviewer; both
  Environments are already restricted to branch `main`.
- [ ] T075 [US4] Run quickstart §3 (a visible change, staging first, then the approved
  promotion, timed against SC-005) and §6:
  - roll back `prod-us` and check that the data counts are unchanged (SC-006);
  - deploy a deliberately unhealthy image to `dev-staging` from a throwaway branch with
    `deploy.yml`, and confirm the self-rollback;
  - delete the throwaway branch and image tag afterwards. The tag is immutable, so delete it
    with `aws ecr batch-delete-image` from the operator shell, or leave it for the lifecycle
    policy.

  Record the results in `docs/ai-build-log.md`.

**Checkpoint**: release, promotion, self-rollback, and manual rollback are all proven.

---

## Phase 7: User Story 5 - Recover an instance without losing data (Priority: P3)

**Goal**:
- A replaced host returns at the same address with its data and certificates.
- A reboot needs no manual step.
- Daily snapshots keep 7.
- Restoring from a snapshot works.
- The data volume cannot be destroyed by accident.

**Independent Test**: [quickstart.md](quickstart.md) §7–§8.

### Tests for User Story 5 (write first; they must fail) ⚠️

- [X] T076 [P] [US5] Write `infra/terraform/shared/tests/backup.tftest.hcl` with mocked
  providers. Assert that `aws_dlm_lifecycle_policy` `${local.name}-daily`:
  - targets `target_tags = { "rentsync:backup" = "daily" }`, with resource type `VOLUME`;
  - runs every 24 hours at `05:00` UTC;
  - has `retain_rule.count == 7` (FR-032);
  - has `copy_tags = true`.

  In the same task, remove the `if [ -e ... ]` guards from the CI `infra` job (T004), now that
  every referenced file exists.

### Implementation for User Story 5

- [X] T077 [US5] Create `infra/terraform/shared/backup.tf`:
  - IAM role `${local.name}-dlm` (trusted by `dlm.amazonaws.com`), with the AWS-managed
    `AWSDataLifecycleManagerServiceRole` policy;
  - `aws_dlm_lifecycle_policy` per T076.

  T076 must pass.
- [X] T078 [US5] Fill in runbook §Host replacement:
  - a `-replace=module.host.aws_instance.this` apply on the deployment's workspace (HCP: "Start
    new run" → "Replace resources");
  - what to expect (the same IP, Caddy logs `certificate loaded`, pending deliveries resume);
  - the 30-minute bound (SC-007);
  - reboot recovery.
- [X] T079 [US5] Fill in runbook §Backup restore (research R14). *Done with `terraform state rm`
  instead of the `removed` block below: Terraform rejects `removed` for a resource the module
  still declares (research R14 implementation note).* Write the exact, deliberate
  override procedure:
  1. choose a snapshot (`aws ec2 describe-snapshots --filters Name=tag:DeploymentId,Values=<id>`);
  2. set the workspace variable `data_snapshot_id`;
  3. in a PR, add `removed { from = module.host.aws_ebs_volume.data  lifecycle { destroy = false } }`
     to `infra/terraform/environment/main.tf`, together with a `moved` or new-address change, so
     a fresh volume is created from the snapshot;
  4. apply;
  5. verify;
  6. delete the orphaned old volume by hand later.

  **Rehearse it on `dev-staging`** before finalizing the wording. Adjust the HCL shape to what
  actually plans cleanly, and record the final shape in the runbook.
- [X] T080 [US5] Fill in runbook §Secret rotation:
  - **admin token**: update the HCP variable, bump `admin_token_version`, apply, then run
    `deploy.yml` with the current tag (`--reload` re-renders the env file);
  - **Postgres password**: bump `postgres_password_version`, apply, open an SSM session, and
    run `ALTER USER postgres PASSWORD '<new value from SSM>'` through
    `docker compose exec postgres psql` without echoing it, then `rentsync-deploy --reload`;
  - **OpenObserve root password**: change the variable, bump the version, apply `shared-us`,
    update the OpenObserve user through its UI or API, and `--reload` both environment hosts.

  Include how to check that the old admin token gets 401.
- [X] T081 [US5] Fill in runbook §Teardown (quickstart §10). *Done by releasing each data
  volume with `terraform state rm`, rather than a PR that flips `prevent_destroy`, which
  `check_prevent_destroy.sh` would reject in CI:*
  1. a PR that temporarily sets `prevent_destroy = false`, the documented override;
  2. destroy `prod-us`, then `dev-staging`, then `shared-us`, emptying ECR first with
     `aws ecr batch-delete-image`;
  3. delete the remaining snapshots, the NameCheap A records, and the bootstrap roles if you
     are leaving for good.

  Also fill in runbook §Adding a side-by-side deployment (FR-042): a new workspace on
  `infra/terraform/environment` with a new `deployment_id`, `private_ip`, `hostname`, and
  secrets; a GitHub Environment with its `SITE_URL`; one entry in `deploy.yml`'s
  `deployment_id` choice list; an A record. Nothing else changes.
- [ ] T082 [US5] **🧑 OPERATOR**: apply `rentsync-shared-us` (DLM), and approve any applies the
  T083 rehearsals need.
- [ ] T083 [US5] Run quickstart §7 (reboot, then replacement, on `dev-staging`) and §8 (the
  snapshot list after a day, the `prevent_destroy` plan error, the restore rehearsal from T079).
  Record the results in `docs/ai-build-log.md`.

**Checkpoint**: recovery is proven on `dev-staging`.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T084 [P] Fill in `docs/deploy/production-differences.md` (FR-036), giving the production
  equivalent and the reason for each demo choice:
  - one VPC vs separate VPCs and accounts;
  - EC2 per environment vs ECS Fargate across availability zones;
  - containerized Postgres and Redis vs RDS and ElastiCache. Note that ElastiCache was priced at
    about $6–9.50 per environment per month and rejected on cost (spec Clarifications);
  - Caddy vs an ALB with ACM;
  - a public subnet vs private subnets with NAT;
  - manual DNS vs Route 53;
  - shared single-host telemetry vs a managed or HA stack.

  Also list the R2 single coarse Terraform role, the R8 root ingest credentials and plain-HTTP
  OTLP inside the VPC, and the single availability zone.
- [X] T085 [P] Write `docs/adr/0005-demo-aws-topology.md`: single VPC, one EC2 host per
  deployment, DeploymentId naming and side-by-side deployments, and fixed ENIs and EIPs. Use the
  context, decision, alternatives, and consequences format of the existing ADRs.
- [X] T086 [P] Write `docs/adr/0006-releases-via-ssm.md` (research R9): releases outside
  Terraform, SSM Run Command, the self-rollback, and the expand-only migrations rule.
- [X] T087 [P] Write `docs/adr/0007-secrets-ssm-write-only.md` (research R11): SSM SecureString,
  write-only arguments, and ephemeral passwords, with Secrets Manager rejected.
- [X] T088 [P] Update `README.md`: the live URLs, a short architecture paragraph linking to
  `docs/deploy/runbook.md`, `docs/deploy/production-differences.md`, and ADRs 0005–0007, and a
  note that this is a cost-conscious demo (constitution §Scope).
- [ ] T089 Run quickstart §9 and §9a:
  - GitHub secret scanning, or `gitleaks detect`, finds nothing (SC-004);
  - admin token rotation on `dev-staging`;
  - the budget configuration;
  - the tag audit;
  - the `rentsync-pr-42` speculative plan, with no changes to existing deployments (SC-011).
    Delete that workspace afterwards.

  Record the results in `docs/ai-build-log.md`.
- [X] T090 Remove the Sync Impact Report HTML comment from the top of
  `.specify/memory/constitution.md`, as governance requires before merge.
- [X] T091 Run the full suite (rspec, rubocop, terraform fmt, validate, and test, shellcheck),
  then append the session entry to `docs/ai-build-log.md`. Open a PR from `002-aws-deployment`
  to `main`, with the quickstart results summarized. Merge only when CI is green and the
  operator has reviewed it. *Merged before the quickstart, by operator decision (see the note
  before T053); the results come in T091a.*
- [ ] T091a After the live-check tasks, summarize the quickstart results in
  `docs/ai-build-log.md`, and land any fixes they needed through PRs to `main`.
- [ ] T092 **🧑 OPERATOR**, starting after the merge: after 30 days of unattended running,
  check SC-009 (Cost Explorer under $60, per-`DeploymentId` breakdown) and SC-010 (certificates
  renewed, `df -h /` and `/srv/data` below 80%). Record the results in `docs/ai-build-log.md`.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: none.
- **Foundational (Phase 2)**: depends on Setup. It blocks every story.
- **US1 (Phase 3)**: depends on Phase 2. **Its operator gates T053 and T054 block all live
  verification in later phases.**
- **US2 (Phase 4)**: depends on US1's infrastructure. Its code (T056–T063) can be written before
  T054 completes.
- **US3 (Phase 5)**: depends on US1. It is independent of US2's code, but T071 needs a deployed
  US2 to produce telemetry.
- **US4 (Phase 6)**: depends on US2 (`build-image.yml`, `deploy-to.yml`, `rentsync-deploy`).
- **US5 (Phase 7)**: depends on US1. Its rehearsals (T083) are most meaningful after US2 has put
  data on `dev-staging`.
- **Polish (Phase 8)**: after the desired stories.

### Story completion graph

```text
Setup → Foundational → US1 ─┬─> US2 ──> US4
                            ├─> US3 (verify after US2)
                            └─> US5 (rehearse after US2)
                                    └──────────────> Polish
```

### Within each phase

- Tests are written and seen to fail, then the implementation follows.
- Terraform tests run against mocked providers. No cloud is needed until the 🧑 OPERATOR apply
  tasks.
- An agent can complete every non-OPERATOR task up to T052, and the code tasks of every later
  phase, without cloud access.

### Parallel opportunities

- Phase 1: T002, T003, T005, T006, T007.
- Phase 2 tests: T008, T009, T010, T011, T012, T023, T024, T025.
- Phase 2 implementation: T014, T015, T016 after T013; T032, T033, T035.
- US1: tests T039 and T040; T042, T045, and T050 alongside the other US1 files.
- US2: T056, T057, T060, T061. US3: T066, T067.
- Polish: T084–T088.

---

## Parallel Example: Phase 2 tests

```bash
Task: "Write mock_pms/spec/unit/settings_spec.rb (T008)"
Task: "Extend mock_pms/spec/unit/logging_spec.rb (T009)"
Task: "Create mock_pms/spec/unit/metrics/exposition_spec.rb (T010)"
Task: "Extend mock_pms/spec/requests/ops_spec.rb (T011)"
Task: "Write infra/terraform/environment/tests/deployment_id.tftest.hcl (T023)"
Task: "Write infra/host/test/boot_volume_test.sh (T025)"
```

## Parallel Example: User Story 2

```bash
Task: "Create infra/host/compose.env.yaml (T056)"
Task: "Create infra/host/Caddyfile.env (T057)"
Task: "Create .github/workflows/build-image.yml (T060)"
Task: "Create .github/workflows/deploy-to.yml (T061)"
```

---

## Implementation Strategy

### MVP first (US1, then US2)

1. Phases 1–2. Everything is verifiable locally and in CI.
2. US1 code through T052. **Stop for the operator** at T053 and T054 (bootstrap, first applies,
   DNS).
3. US1 verification (T055).
4. US2, giving the first real reachable PMS. US1 and US2 together are the MVP: a working,
   deployed mock PMS on both deployments.

### Incremental delivery

5. US3: telemetry in one place.
6. US4: automated release and promotion.
7. US5: recovery proven.
8. Polish, then the PR.

### Unattended-session guidance

When the operator is away, an agent works through every non-OPERATOR task in order. At each
**🧑 OPERATOR** task, it records the task as blocked in `docs/ai-build-log.md` and continues with
later tasks that don't need cloud state: code, tests, and docs. It never attempts console steps,
never asks for credentials, and never applies to `prod-us` or `shared-us`.

---

## Notes

- [P] tasks touch different files and have no unfinished dependencies.
- Check off each task as it is completed (CLAUDE.md).
- Commit after each task or logical group, with the full suite green.
- If a test looks wrong, stop and log it in `docs/ai-build-log.md`. Never weaken it.
