# Contract: HCP Terraform workspace inputs and outputs

All variables are workspace variables of category "terraform", unless they are marked env.
Values in angle brackets come from the deployment settings (`bootstrap-init.sh`), and
`bootstrap-hcp.rb` sets every variable that has no default.
"Sensitive" means marked sensitive in HCP Terraform *and* declared `ephemeral = true` in
Terraform, so the value never reaches state or plan files.

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
| `telemetry_private_ip` | string | — | no | `10.40.1.10`. Configuration, not hard-coded |
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
| `vpc_id`, `subnet_id`, `otlp_client_security_group_id` | environment root, via `terraform_remote_state`. Environment hosts attach the OTLP client group, which the telemetry group admits on 5080, so adding a deployment never edits shared rules |
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
| `private_ip` | string | `10.40.1.20` | `10.40.1.30` | no |
| `instance_type` | string | `t4g.small` | `t4g.small` | no |
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
