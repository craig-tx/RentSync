# Contract: HCP Terraform workspace inputs and outputs

All variables are workspace variables of category "terraform", unless they are marked env.
Values in angle brackets come from the deployment settings (`bootstrap-init.sh`), and
`bootstrap-hcp.rb` sets every variable that has no default.
"Sensitive" means marked sensitive in HCP Terraform *and* declared `ephemeral = true` in
Terraform, so the value never reaches state or plan files.

## Who owns a variable after bootstrap

`bootstrap-hcp.rb` creates each variable once and never changes it on a rerun, because the
operator owns it from then on (runbook §Bootstrap step 2, "Reruns"). Workspace *settings*, by
contrast, are restored on every rerun. These variables are expected to change, each through a
runbook procedure:

| Variable | Workspaces | Changed by | Why |
|---|---|---|---|
| `acme_ca` | all three | §DNS | starts at Let's Encrypt staging; switched to production once DNS resolves |
| `ami_id` | `rentsync-shared-us` | §Monthly OS patching | each patch pins a newer Amazon Linux AMI |
| `instance_type`, `telemetry_instance_type` | environments, shared | §Changing a host's instance type | resizing a host; not set by bootstrap |
| `admin_token`, `admin_token_version` | environments | §Secret rotation | rotation sets a new token and bumps the version |
| `openobserve_root_password`, `openobserve_root_password_version`, `postgres_password_version` | as listed below | §Secret rotation | the same |
| `openobserve_db_password_version` | `rentsync-shared-us` | **no procedure yet** | bumping it writes a new password to SSM, but OpenObserve's Postgres keeps the old one until changed by hand, as in the Postgres procedure; don't bump it until the runbook covers it |
| `data_snapshot_id` | environments | §Backup restore | set to restore a data volume from a snapshot |

Every other variable describes the deployment itself (its ID, network, hostnames, emails). It
changes only by editing it in the workspace, for example after moving to a new domain.

## Project variable set `rentsync-aws` (applied to project `RentSync`)

| Key | Category | Value | Sensitive |
|---|---|---|---|
| `TFC_AWS_PROVIDER_AUTH` | env | `true` | no |
| `TFC_AWS_RUN_ROLE_ARN` | env | `arn:aws:iam::<aws-account-id>:role/rentsync-hcp-terraform` | no |
| `TF_CLOUD_ORGANIZATION` | env | `<hcp-organization>`; the `cloud` blocks name no organization | no |

## `rentsync-shared-us` → `infra/terraform/shared`

| Variable | Type | Default | Sensitive | Notes |
|---|---|---|---|---|
| `deployment_id` | string (validated, constitution VI) | — | no | `shared-us` |
| `region` | string | — | no | AWS region, from the deployment settings |
| `telemetry_private_ip` | string | — | no | `10.40.1.10`, in the shared VPC (`10.40.0.0/16`). Configuration, not hard-coded |
| `vpc_cidr`, `subnet_cidr` | string | — | no | `10.40.0.0/16`, `10.40.1.0/24` |
| `availability_zone` | string | — | no | All hosts and volumes live here; from the settings |
| `ami_id` | string | — | no | Pinned Amazon Linux 2023 arm64 AMI |
| `telemetry_instance_type` | string | `t4g.small` | no | |
| `telemetry_hostname` | string | — | no | `telemetry.<domain>` |
| `acme_email` | string | — | no | Let's Encrypt contact |
| `acme_ca` | string | `https://acme-v02.api.letsencrypt.org/directory` | no | Set to the LE staging URL for first bring-up |
| `openobserve_root_email` | string | — | no | UI sign-in user |
| `openobserve_root_password` | string | — | **yes** | 8–128 characters, with upper, lower, digit and special |
| `openobserve_root_password_version` | number | `1` | no | Bump to rotate |
| `openobserve_db_password_version` | number | `1` | no | Bump to regenerate |
| `budget_limit_usd` | number | `60` | no | SC-009 |
| `budget_email` | string | — | no | Alert recipient. Not committed |

**Outputs**:

| Output | Used by |
|---|---|
| `vpc_id`, `vpc_cidr`, `route_table_id`, `telemetry_security_group_id` | environment root, via `terraform_remote_state`. Each environment peers its own VPC with `vpc_id`, routes to `vpc_cidr`, adds its return route to `route_table_id`, and admits its subnet to the telemetry group on 5080, all from its own state, so adding a deployment never edits shared code (ADR-0008) |
| `availability_zone`, `ami_id` | environment root (one place to pin them) |
| `ecr_repository_url` | environment root (host env), release workflow (repository variable) |
| `otlp_endpoint` (`http://10.40.1.10:5080/api/default`) | environment root |
| `telemetry_public_ip` | DNS record (runbook) |

## `rentsync-dev-staging` / `rentsync-prod-us` → `infra/terraform/environment`

| Variable | Type | `rentsync-dev-staging` | `rentsync-prod-us` | Sensitive |
|---|---|---|---|---|
| `deployment_id` | string (validated, constitution VI) | `dev-staging` | `prod-us` | no |
| `environment` | string (`staging`\|`production`) | `staging` | `production` | no |
| `shared_workspace` | string | `rentsync-shared-us` | `rentsync-shared-us` | no |
| `hcp_organization` | string | `<hcp-organization>` | `<hcp-organization>` | no |
| `region` | string | the AWS region from the settings | the same | no |
| `hostname` | string | `pms-staging.<domain>` | `pms.<domain>` | no |
| `vpc_cidr` | string | `10.41.0.0/16` | `10.42.0.0/16` | no |
| `subnet_cidr` | string | `10.41.1.0/24` | `10.42.1.0/24` | no |
| `private_ip` | string | `10.41.1.20` | `10.42.1.30` | no |
| `instance_type` | string | `t4g.micro` (default) | `t4g.micro` (default) | no |
| `acme_email`, `acme_ca` | string | as for shared | as for shared | no |
| `admin_token` | string (validated: ≥ 32 characters, not `change-me-admin-token`) | random, per environment | different random | **yes** |
| `admin_token_version` | number | `1` | `1` | no |
| `postgres_password_version` | number | `1` | `1` | no |
| `protected` | bool | `false` | `true` | no |
| `data_snapshot_id` | string | `null` | `null` | no |

`data_snapshot_id` is used only by the restore procedure (research R14). `protected = true`
tags the host `rentsync:deployable = protected`, so only `rentsync-github-actions-prod` can
deploy to it.

**Outputs**: `public_ip` (for DNS), `instance_id`, `url` (`https://<hostname>`).

## GitHub repository configuration (not Terraform)

| Item | Kind | Value |
|---|---|---|
| `AWS_BUILD_ROLE_ARN` | Actions variable | `arn:aws:iam::<aws-account-id>:role/rentsync-github-build` (the only role that can push images; trusted for `main` only) |
| `AWS_ROLE_ARN` | Actions variable | `arn:aws:iam::<aws-account-id>:role/rentsync-github-actions` (non-production deploys; trusted for `environment:dev-staging` only) |
| `ECR_REPOSITORY_URL` | Actions variable | shared output `ecr_repository_url` |
| `AWS_REGION` | Actions variable | the AWS region from the settings |
| `dev-staging` | Environment (named by DeploymentId) | no protection rules; branch `main` only; Environment variable `SITE_URL = https://pms-staging.<domain>` |
| `prod-us` | Environment (named by DeploymentId) | required reviewer: the operator; branch `main` only; `SITE_URL = https://pms.<domain>`; `AWS_ROLE_ARN = arn:aws:iam::<aws-account-id>:role/rentsync-github-actions-prod` (overrides the repository variable) |

None of these values are secrets. GitHub Actions authenticates to AWS through OIDC, so there is
no access key anywhere.
