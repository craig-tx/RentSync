# RentSync deployment runbook

Operator procedures for the AWS deployment of the mock PMS (feature 002). Design and rationale:
[specs/002-aws-deployment/](../../specs/002-aws-deployment/). End-to-end validation:
[quickstart.md](../../specs/002-aws-deployment/quickstart.md).

Deployments (constitution Principle VI, DeploymentId):

| DeploymentId | Serves | HCP workspace | URL |
|---|---|---|---|
| `shared-us` | VPC, ECR, telemetry, backups, budget | `rentsync-shared-us` | `https://telemetry.rentsync.org` |
| `dev-staging` | staging | `rentsync-dev-staging` | `https://pms-staging.rentsync.org` |
| `prod-us` | production | `rentsync-prod-us` | `https://pms.rentsync.org` |

## Bootstrap

This one-time setup, done by hand, should take under an hour (FR-006). It creates no AWS access
keys, and no credential ever goes into chat, the repository, or a terminal history. Afterwards,
every change goes through HCP Terraform runs. Note the start time; T053 records how long it took.

You need an AWS account (region `us-east-1`), owner access to the HCP Terraform organization
`craig-personal`, admin access to `craig-tx/RentSync` on GitHub, and the NameCheap account for
`rentsync.org`.

### 1. AWS: OIDC identity providers

Open IAM → **Identity providers** → **Add provider**, choose **OpenID Connect**, and add these
two providers:

| Provider URL | Audience |
|---|---|
| `https://app.terraform.io` | `aws.workload.identity` |
| `https://token.actions.githubusercontent.com` | `sts.amazonaws.com` |

### 2. AWS: the two bootstrap roles

Each policy file in [`iam/`](iam/) uses `<account>` as a placeholder. Replace it with your
12-digit account ID before pasting.

1. Open IAM → **Policies** → **Create policy** → **JSON**. Paste
   [`iam/hcp-terraform-policy.json`](iam/hcp-terraform-policy.json) and name it
   `rentsync-hcp-terraform`.
2. Open IAM → **Roles** → **Create role** → **Custom trust policy**. Paste
   [`iam/hcp-terraform-trust.json`](iam/hcp-terraform-trust.json), attach the
   `rentsync-hcp-terraform` policy, and name the role `rentsync-hcp-terraform`.
3. Create the policy `rentsync-github-actions` from
   [`iam/github-actions-policy.json`](iam/github-actions-policy.json).
4. Create the role `rentsync-github-actions` from
   [`iam/github-actions-trust.json`](iam/github-actions-trust.json), and attach the
   `rentsync-github-actions` policy.
5. Copy both role ARNs into the table at the end of this section.

### 3. AWS: pick the AMI

Find the current Amazon Linux 2023 arm64 AMI:

```bash
aws ssm get-parameter --region us-east-1 \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text
```

Record the `ami-…` ID. It is pinned on purpose: changing it later replaces every host
(research R4).

### 4. HCP Terraform: project and variable set

1. In organization `craig-personal`, go to **Projects** → **New project** and name it
   `RentSync`.
2. Go to **Settings** → **Variable sets** → **Create variable set**. Name it `rentsync-aws`, and
   apply it to the project `RentSync`. Add two **Environment** variables, neither of them
   sensitive:

   | Key | Value |
   |---|---|
   | `TFC_AWS_PROVIDER_AUTH` | `true` |
   | `TFC_AWS_RUN_ROLE_ARN` | the `rentsync-hcp-terraform` role ARN |

### 5. HCP Terraform: workspaces

Create each workspace in project `RentSync`:

1. Choose **New** → **Workspace** → **Version control workflow** → GitHub → `craig-tx/RentSync`.
2. Under **Advanced options**, set the **Terraform working directory**, the VCS branch `main`,
   and the trigger pattern `infra/**`.
3. After creating it, open **Settings** → **General**:
   - set **Terraform version** to `1.16.6`;
   - set the **Apply method** as shown in the table;
   - add the workspace tag shown in the table. The `cloud` block in `versions.tf` selects
     workspaces by these tags.

| Workspace | Working directory | Apply method | Tag |
|---|---|---|---|
| `rentsync-shared-us` | `infra/terraform/shared` | Manual apply | `rentsync-shared` |
| `rentsync-dev-staging` | `infra/terraform/environment` | **Auto apply** | `rentsync-environment` |
| `rentsync-prod-us` | `infra/terraform/environment` | Manual apply | `rentsync-environment` |

Then finish the workspace settings:

- In `rentsync-shared-us`, open **Settings** → **General** → **Remote state sharing**. Choose
  **Share with specific workspaces**, and add `rentsync-dev-staging` and `rentsync-prod-us`.
  Without this, the environment workspaces can't read the shared outputs.
- In each workspace, open **Settings** → **Health** and turn on drift detection if your plan
  includes it. Without it, any plan still shows drift (FR-005).

### 6. HCP Terraform: workspace variables

All of these are **Terraform** variables. Mark the sensitive ones **Sensitive**. Generate each
`admin_token` on your own machine with `openssl rand -hex 32`, separately for each
environment, and paste it straight into HCP. Don't store it anywhere else.

`rentsync-shared-us`:

| Variable | Value | Sensitive |
|---|---|---|
| `deployment_id` | `shared-us` | no |
| `ami_id` | AMI from step 3 | no |
| `telemetry_private_ip` | `10.40.1.10` | no |
| `acme_email` | your contact email | no |
| `acme_ca` | `https://acme-staging-v02.api.letsencrypt.org/directory` (first bring-up; see §DNS) | no |
| `openobserve_root_email` | the OpenObserve sign-in email | no |
| `openobserve_root_password` | 8–128 characters, with upper, lower, digit and special | **yes** |
| `budget_email` | budget alert recipient | no |

`rentsync-dev-staging` and `rentsync-prod-us`:

| Variable | `rentsync-dev-staging` | `rentsync-prod-us` | Sensitive |
|---|---|---|---|
| `deployment_id` | `dev-staging` | `prod-us` | no |
| `environment` | `staging` | `production` | no |
| `hostname` | `pms-staging.rentsync.org` | `pms.rentsync.org` | no |
| `private_ip` | `10.40.1.20` | `10.40.1.30` | no |
| `acme_email` | your contact email | your contact email | no |
| `acme_ca` | the Let's Encrypt staging URL, as above | the Let's Encrypt staging URL, as above | no |
| `admin_token` | `openssl rand -hex 32` | a different `openssl rand -hex 32` | **yes** |

Everything else keeps the defaults in `variables.tf` (contracts/workspace-variables.md).

### 7. GitHub: variables and Environments

1. Go to **Settings** → **Secrets and variables** → **Actions** → **Variables**, and add
   `AWS_ROLE_ARN` (the `rentsync-github-actions` ARN) and `AWS_REGION` (`us-east-1`). Add
   `ECR_REPOSITORY_URL` after the first `rentsync-shared-us` apply, from its
   `ecr_repository_url` output.
2. Go to **Settings** → **Environments** and create `dev-staging` and `prod-us`. In each
   Environment:
   - add the Environment variable `SITE_URL`: `https://pms-staging.rentsync.org` for
     `dev-staging` and `https://pms.rentsync.org` for `prod-us`. This is the only place
     deployment URLs are recorded;
   - restrict deployment branches to `main`.

   The `prod-us` required reviewer is added in task T074.
3. Go to **Settings** → **Code security** and confirm that secret scanning and push protection
   are on. They are free for public repositories (SC-004).

### 8. AWS Billing: cost allocation tag

About a day after the first apply, go to Billing → **Cost allocation tags** → **User-defined**.
Select `DeploymentId` and choose **Activate**. Cost Explorer can then group spend by
deployment (constitution VI).

### Values to record

Every value below is non-secret. Fill them in as you go.

| Value | Where it comes from | Where it is entered |
|---|---|---|
| AWS account ID | AWS console, top right | the `iam/*.json` placeholders |
| Region | `us-east-1` | variable defaults; GitHub `AWS_REGION` |
| HCP organization | `craig-personal` | `versions.tf` (`cloud` block) |
| `rentsync-hcp-terraform` role ARN | step 2 | variable set `TFC_AWS_RUN_ROLE_ARN` |
| `rentsync-github-actions` role ARN | step 2 | GitHub `AWS_ROLE_ARN` |
| AMI ID | step 3 | `rentsync-shared-us` `ami_id` |
| ECR repository URL | `rentsync-shared-us` output `ecr_repository_url` | GitHub `ECR_REPOSITORY_URL` |

## DNS

Terraform does not manage DNS (FR-021). After the first applies, create three A records at
NameCheap (**Domain List** → `rentsync.org` → **Manage** → **Advanced DNS** → **Add new
record**):

| Type | Host | Value (workspace output) | TTL |
|---|---|---|---|
| A Record | `telemetry` | `rentsync-shared-us` → `telemetry_public_ip` | 5 min |
| A Record | `pms-staging` | `rentsync-dev-staging` → `public_ip` | 5 min |
| A Record | `pms` | `rentsync-prod-us` → `public_ip` | 5 min |

Recorded addresses (filled in at task T054):

| Host | Elastic IP |
|---|---|
| `telemetry.rentsync.org` | _TBD_ |
| `pms-staging.rentsync.org` | _TBD_ |
| `pms.rentsync.org` | _TBD_ |

Check that each record resolves:

```bash
for h in telemetry pms-staging pms; do echo "$h -> $(dig +short $h.rentsync.org)"; done
```

**Switching to production certificates**: hosts first come up with `acme_ca` pointing at the
Let's Encrypt staging endpoint. That avoids rate limits while DNS propagates, but its
certificates are not publicly trusted. Once every record resolves to its IP:

1. Set `acme_ca` to `https://acme-v02.api.letsencrypt.org/directory` in all three workspaces.
2. Apply `rentsync-shared-us` (confirm), then `rentsync-dev-staging`, then `rentsync-prod-us`
   (confirm). Changing the host configuration replaces each host. Its address and data are
   kept (research R6).
3. Check with `curl -sv https://pms-staging.rentsync.org/healthz 2>&1 | grep issuer`, which
   should name a Let's Encrypt production issuer.

After bring-up, set the TTLs back to **Automatic**. The records never change again, because
the Elastic IPs survive host replacement.

## First deploy

TBD (task T063).

## Release and promotion

TBD (task T073).

## Rollback

TBD (task T073).

## Host replacement

TBD (task T078).

## Backup restore

TBD (task T079).

## Secret rotation

TBD (task T080).

## Replaying failed webhooks on a deployed environment

TBD (task T063).

## Adding a side-by-side deployment

TBD (task T081).

## Teardown

TBD (task T081).
