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

### 1–2. AWS: OIDC providers and bootstrap roles, from CloudShell (recommended)

[`infra/bootstrap/bootstrap-iam.sh`](../../infra/bootstrap/bootstrap-iam.sh) does steps 1 and 2
with the AWS CLI. Run it in **AWS CloudShell**, which acts as your console session, so no access
key is created. It reads the account ID from that session, writes filled-in copies of the
[`iam/`](iam/) files to the gitignored `.bootstrap/iam/`, and validates each one with IAM Access
Analyzer. It is safe to rerun: it skips what exists, and refreshes the trust policy of a role
that exists.

1. Sign in as an administrator, switch to `us-east-1`, and open **CloudShell** from the top bar.
2. Clone the repository. Before feature 002 merges, add `--branch 002-aws-deployment`:

   ```bash
   git clone https://github.com/craig-tx/RentSync.git && cd RentSync
   ```

3. Print the plan. It changes nothing; review the `+ aws …` lines it lists:

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh
   ```

4. Make the changes. The script ends by printing the four role ARNs, each with the variable
   it goes into (steps 4 and 7):

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh --apply
   ```

   An existing policy is never changed automatically. If the script reports one, compare it
   with the rendered file and run the `create-policy-version` command it prints. If
   `create-role` fails with "Invalid principal" right after the providers were created, IAM
   hasn't caught up yet. Wait a few seconds and rerun.

The console steps below do the same by hand. Skip to step 3 if the script succeeded.

### 1. AWS: OIDC identity providers (console)

Open IAM → **Identity providers** → **Add provider**, choose **OpenID Connect**, and add these
two providers:

| Provider URL | Audience |
|---|---|
| `https://app.terraform.io` | `aws.workload.identity` |
| `https://token.actions.githubusercontent.com` | `sts.amazonaws.com` |

### 2. AWS: the bootstrap roles (console)

Each policy file in [`iam/`](iam/) uses `<account>` as a placeholder. Don't edit them in place.
Write paste-ready copies to the gitignored `.bootstrap/iam/` and paste from there:

```bash
bash infra/bootstrap/bootstrap-iam.sh --render-only <your 12-digit account ID>
```

A placeholder left in a pasted document makes IAM fail with "The policy failed legacy parsing".

1. Open IAM → **Policies** → **Create policy** → **JSON**. Paste
   [`iam/hcp-terraform-policy.json`](iam/hcp-terraform-policy.json) and name it
   `rentsync-hcp-terraform`.
2. Open IAM → **Roles** → **Create role** → **Custom trust policy**. Paste
   [`iam/hcp-terraform-trust.json`](iam/hcp-terraform-trust.json), attach the
   `rentsync-hcp-terraform` policy, and name the role `rentsync-hcp-terraform`.
3. Create the policy `rentsync-github-build` from
   [`iam/github-build-policy.json`](iam/github-build-policy.json), and the role
   `rentsync-github-build` from [`iam/github-build-trust.json`](iam/github-build-trust.json).
   It trusts only jobs on `main`, and it is the only role that can push images.
4. Create the policy `rentsync-github-actions` from
   [`iam/github-actions-policy.json`](iam/github-actions-policy.json), and the role
   `rentsync-github-actions` from [`iam/github-actions-trust.json`](iam/github-actions-trust.json).
   It trusts only the `dev-staging` Environment, deploys **non-production** hosts, and cannot
   push images.
5. Create the policy `rentsync-github-actions-prod` from
   [`iam/github-actions-prod-policy.json`](iam/github-actions-prod-policy.json), and the role
   `rentsync-github-actions-prod` from
   [`iam/github-actions-prod-trust.json`](iam/github-actions-prod-trust.json). Its trust accepts
   only the `prod-us` GitHub Environment, and it is the only role that can run commands on
   production hosts. IAM, not just the workflow, enforces the approval gate.
6. Note the four role ARNs for steps 4 and 7. The table at the end of this section says where
   each one goes.
7. As you paste each policy, open the policy editor's **Policy validation** panel (IAM Access
   Analyzer) and resolve any error or security warning before saving.

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
| `protected` | `false` (default; leave unset) | `true` | no |

Everything else keeps the defaults in `variables.tf` (contracts/workspace-variables.md).

### 7. GitHub: variables and Environments

1. Go to **Settings** → **Secrets and variables** → **Actions** → **Variables**, and add
   `AWS_BUILD_ROLE_ARN` (the `rentsync-github-build` ARN), `AWS_ROLE_ARN` (the
   `rentsync-github-actions` ARN) and `AWS_REGION` (`us-east-1`). Add
   `ECR_REPOSITORY_URL` after the first `rentsync-shared-us` apply, from its
   `ecr_repository_url` output.
2. Go to **Settings** → **Environments** and create `dev-staging` and `prod-us`. In each
   Environment:
   - add the Environment variable `SITE_URL`: `https://pms-staging.rentsync.org` for
     `dev-staging` and `https://pms.rentsync.org` for `prod-us`. This is the only place
     deployment URLs are recorded;
   - in **`prod-us` only**, add the Environment variable `AWS_ROLE_ARN` = the
     `rentsync-github-actions-prod` ARN. It overrides the repository variable for production
     jobs;
   - restrict deployment branches to `main`. This is **required, not optional**: the release
     roles trust these Environments by name, so a branch must not be able to run a job in them.

   The `prod-us` required reviewer is added in task T074.
3. Go to **Settings** → **Code security** and confirm that secret scanning and push protection
   are on. They are free for public repositories (SC-004).

### 8. AWS Billing: cost allocation tag

About a day after the first apply, go to Billing → **Cost allocation tags** → **User-defined**.
Select `DeploymentId` and choose **Activate**. Cost Explorer can then group spend by
deployment (constitution VI).

### Values to record

Every value below is non-secret, but don't write them into this file: the repository is
public and stays account-neutral. Enter each value where the last column says. Those places
are the record.

| Value | Where it comes from | Where it is entered |
|---|---|---|
| AWS account ID | AWS console, top right | read by `bootstrap-iam.sh`; `--render-only` for the console path |
| Region | `us-east-1` | variable defaults; GitHub `AWS_REGION` |
| HCP organization | `craig-personal` | `versions.tf` (`cloud` block) |
| `rentsync-hcp-terraform` role ARN | step 2 | variable set `TFC_AWS_RUN_ROLE_ARN` |
| `rentsync-github-build` role ARN | step 2 | GitHub repository variable `AWS_BUILD_ROLE_ARN` |
| `rentsync-github-actions` role ARN | step 2 | GitHub repository variable `AWS_ROLE_ARN` |
| `rentsync-github-actions-prod` role ARN | step 2 | GitHub `prod-us` Environment variable `AWS_ROLE_ARN` |
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

This assumes Bootstrap and DNS are done, **including the switch to Let's Encrypt production
certificates** (§DNS), so every workspace has been applied with the production `acme_ca`. The
Deploy workflow's final check verifies the certificate from the internet, and a staging-CA
certificate fails it. Switching before the first deploy is also free, because the hosts it
replaces hold no data yet.

Each host boots with Caddy only and prints `no image deployed yet`. The first image goes out
with the **Deploy** workflow:

1. In GitHub → **Actions** → **Deploy** → **Run workflow**, with **Use workflow from: `main`**
   (only `main` may build images), choose `deployment_id` `dev-staging` and set `image_tag` to
   the full SHA of the current `main` commit (`git rev-parse origin/main`).
   - The `build` job builds the arm64 image and pushes it to ECR, unless that tag already
     exists, and outputs the image digest. The deploy pins `<sha>@sha256:<digest>`, so the host
     runs exactly that image.
   - The `deploy` job runs `rentsync-deploy <sha>` on the host through SSM Run Command, then
     checks `$SITE_URL/healthz` from the internet.
   - On the first deploy, `bin/setup --deploy` creates and migrates `mock_pms_dev_staging` and
     seeds it, because it has no operators yet. Later deploys only migrate (FR-030).
2. Check it:

   ```bash
   curl -s https://pms-staging.rentsync.org/healthz | jq
   ```

   It should show `"status":"ok"`, `"version":"<sha>"` and `"deployment_id":"dev-staging"`.
3. Run **Deploy** again with `prod-us` and the **same** SHA, then approve it in the run's
   **Review deployments** prompt. Nothing is rebuilt (FR-027).

If a run fails, the job log shows `rentsync-deploy`'s output. `rolled back to <sha>` means
the host is still on its previous image. On a first deploy there is nothing to roll back to,
so it prints `FAILED: environment unhealthy`. In that case, open a shell
(`aws ssm start-session --target <instance_id>`) and look at the stack:

```bash
sudo docker compose -p rentsync-dev-staging --project-directory /opt/rentsync \
  -f /opt/rentsync/compose.yaml --env-file /run/rentsync/env ps
sudo journalctl -u rentsync.service --no-pager | tail -50
```

Avoid `docker compose config` on a host: it prints the rendered secrets.

## Release and promotion

Releases happen outside Terraform (ADR 0006, research R9). Every merge to `main` whose **CI**
run succeeds starts **Release** (`.github/workflows/release.yml`):

1. **`build`** builds `mock_pms` for arm64 from the merge commit and pushes
   `<ECR>/shared-us/mock_pms:<sha>`. Tags are immutable, and an existing tag is skipped.
   Releases are skipped until the bootstrap has set `ECR_REPOSITORY_URL`.
2. **`deploy-dev-staging`** runs `rentsync-deploy <sha>` on the `dev-staging` host, then checks
   `https://pms-staging.rentsync.org/healthz` for `status=ok`, `version=<sha>` and
   `deployment_id=dev-staging`. The target is 15 minutes from merge (SC-005).
3. **`deploy-prod-us`** waits for you. Open the run → **Review deployments** → `prod-us` →
   **Approve and deploy**. It deploys the **same** SHA (FR-027) and checks
   `https://pms.rentsync.org/healthz`. The target is 10 minutes after approval.

Watch it under GitHub → **Actions** → **Release**. Releases run one at a time: a newer merge
waits for the current one.

**What a failed release looks like.** If the new image never reports healthy within about
2 minutes, `rentsync-deploy` puts the previous image back by itself. The job log ends with:

```text
rentsync-deploy: <sha> failed its health check
rolled back to <previous sha>
status: Failed
```

The workflow goes red and GitHub emails you. The environment keeps serving the previous
version, and SSM still records it as `image_tag`. Fix forward with a new merge. If the
rollback also failed, the log says `FAILED: environment unhealthy`; see §First deploy for
how to inspect the host.

**Migrations must be expand-only.** A rollback runs version N−1's code against version N's
schema. So a release may add tables, columns or indexes, but never drop or rename one in the
same release that stops using it. Remove the old column one release later, once nothing
deployed reads it (research R9).

## Rollback

There is one documented action (FR-029). In GitHub → **Actions** → **Deploy** → **Run
workflow**, choose the `deployment_id`, leave `image_tag` empty, and tick **rollback**. A
`prod-us` run waits for approval.

`rentsync-deploy --rollback` deploys `previous_image_tag` and swaps the two parameters. A second
rollback therefore returns to where you started. The data is untouched: no reseed, and no
down-migration (SC-006, under 10 minutes). Afterwards, check:

```bash
curl -s https://pms.rentsync.org/healthz | jq -r .version   # the previous SHA
```

If a `prod-us` release is still waiting for approval, the manual rollback queues behind it,
because deploys to one deployment run one at a time. Reject the pending release in its run
(**Review deployments** ? **Reject**), and the rollback proceeds.

To return to a specific version instead, run **Deploy** with that SHA in `image_tag`. It must
still be in ECR, which keeps the last 100 images.

## Host replacement

A host is disposable; its data is not. The Elastic IP, the network interface (with its
private IP) and the data volume stay when the instance is replaced (FR-008, FR-031). The
volume holds Postgres (or OpenObserve) and Caddy's certificates.

**Planned replacement** (an AMI upgrade, a new instance type, or "just rebuild it"):

1. In the deployment's HCP workspace (for example `rentsync-dev-staging`), choose **New run**
   → **Plan and apply**.
2. Under **Additional planning options**, add the replace address
   `module.host.aws_instance.this`. For the telemetry host in `rentsync-shared-us`, use
   `module.telemetry_host.aws_instance.this`.
3. The plan should show **1 to replace**: the instance, plus the volume attachment that goes
   with it. It must show no change to the EIP, the network interface or `aws_ebs_volume.data`.
   Confirm.

These workspaces are connected to GitHub, so they don't accept a CLI `terraform apply`. Start
the run from the HCP UI.

An AMI or `instance_type` variable change, or any change to the host files, replaces the
host the same way, because user data changes force replacement (research R6).

**What to expect** (under 30 minutes, SC-007):

- Terraform stops the old instance cleanly, detaches the data volume, and destroys the
  instance. It then creates the new one, attaches the volume, and re-associates nothing,
  because the EIP lives on the network interface.
- On boot, `rentsync-boot` finds an existing filesystem, so it **mounts without formatting**.
  `rentsync.service` then runs `rentsync-deploy --reload`, which brings back the image recorded
  in `image_tag`.
- Caddy logs that it loaded the certificate from storage and makes no new ACME order. Check
  this in a session with `docker logs rentsync-dev-staging-caddy-1 2>&1 | grep -i certificate`.
- Pending webhook deliveries resume from the outbox. Delivery is at-least-once (FR-030).
- There is no DNS change.

**Unplanned loss** (the instance was terminated): run a normal plan in the workspace. It
recreates the instance, and the rest of the steps are the same.

**Reboot or stop/start**: no action is needed (US5 AC5). systemd mounts the volume, Docker
waits for it, and `rentsync.service` re-renders secrets and starts the stack.

## Backup restore

AWS Data Lifecycle Manager snapshots every data volume daily at 05:00 UTC and keeps 7
(FR-032). Restoring means replacing a deployment's data volume with one created from a
snapshot. `prevent_destroy` blocks that by design (FR-034), so this procedure is the
deliberate override. It **keeps the old volume** for forensics.

This needs the Terraform CLI signed in to HCP (`terraform login`, which opens a browser for
your own user token) and AWS CLI access. Example for `dev-staging`; rehearse it there before
you ever need it on `prod-us` (task T083).

1. **Pick a snapshot:**

   ```bash
   aws ec2 describe-snapshots --region us-east-1 --owner-ids self \
     --filters Name=tag:DeploymentId,Values=dev-staging \
     --query 'reverse(sort_by(Snapshots,&StartTime))[].[SnapshotId,StartTime,VolumeSize]' --output table
   ```

2. **Release the current volume from Terraform's management** (the override). It stays in
   AWS, attached and untouched:

   ```bash
   cd infra/terraform/environment
   export TF_WORKSPACE=rentsync-dev-staging
   terraform init
   terraform state rm 'module.host.aws_ebs_volume.data'
   ```

   A `removed { … destroy = false }` block can't do this here, because the module still
   declares the volume. `terraform state rm` is the explicit, audited equivalent: HCP records a
   new state version.
3. In the HCP workspace, set the variable `data_snapshot_id` to the chosen `snap-…`, then start
   a run. The plan should show:
   - **create** `aws_ebs_volume.data`, from the snapshot;
   - **replace** `aws_volume_attachment.data`;
   - **replace** `aws_instance.this`, because the user data holds the volume ID.

   Confirm.
4. **Verify**: `/healthz` is ok, and the data matches the snapshot time. For example,
   `GET /admin/clients` shows the clients that existed then. Anything newer than the snapshot
   is gone (at most 24 hours, SC-007).
5. **Leave `data_snapshot_id` set.** Clearing it would plan a replacement of the new volume,
   which `prevent_destroy` correctly refuses.
6. **Delete the old volume** once you no longer need it. The old volume is the one in
   `available` state with the deployment's Name tag:

   ```bash
   aws ec2 describe-volumes --region us-east-1 \
     --filters Name=tag:DeploymentId,Values=dev-staging Name=status,Values=available \
     --query 'Volumes[].[VolumeId,CreateTime]' --output table
   aws ec2 delete-volume --region us-east-1 --volume-id vol-…
   ```

## Secret rotation

A new value goes into HCP (or a version bump generates one). The apply writes it to SSM through
a write-only argument, so it never appears in state or logs. Then the containers pick it up
with a **reload**. Run **Deploy** with the deployment, `image_tag` empty, and **reload**
ticked. Re-deploying the same SHA would be a no-op.

**Admin token** (per environment):

1. On your machine, run `openssl rand -hex 32`. In the workspace, replace the `admin_token`
   variable (Sensitive) and increase `admin_token_version` by 1.
2. Apply. `rentsync-dev-staging` applies on its own; `rentsync-prod-us` needs you to confirm.
3. Run **Deploy** with **reload** for that deployment.
4. Check:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "$BASE/admin/clients" -H "Authorization: Bearer $OLD"   # 401
   curl -s -o /dev/null -w '%{http_code}\n' "$BASE/admin/clients" -H "Authorization: Bearer $NEW"   # 200
   ```

**Postgres password** (per environment). The database keeps its old password until it is told
otherwise, so run these steps back to back:

1. Increase `postgres_password_version` by 1 and apply. A new random password is written to
   SSM.
2. Open a session (`aws ssm start-session --target <instance_id>`), then run:

   ```bash
   sudo -i
   NEW="$(aws ssm get-parameter --region us-east-1 --with-decryption \
     --name /rentsync/dev-staging/postgres_password --query Parameter.Value --output text)"
   printf "ALTER USER postgres PASSWORD '%s';\n" "$NEW" \
     | docker exec -i rentsync-dev-staging-postgres-1 psql -U postgres -q
   unset NEW
   /usr/local/bin/rentsync-deploy --reload
   ```

   The password goes to `psql` on stdin, so it never appears in a process list or in shell
   history. Between the `ALTER USER` and the reload, the app can't open new connections for a
   few seconds.

**OpenObserve root password** (shared). OpenObserve reads `ZO_ROOT_USER_PASSWORD` only when it
first initializes, so change the account itself first:

1. Sign in to `https://telemetry.rentsync.org` → **IAM** → **Users** → the root user →
   **Change password**, and set the new value.
2. In `rentsync-shared-us`, set `openobserve_root_password` to the same value and increase
   `openobserve_root_password_version` by 1. Apply (confirm). Both the root and ingest
   parameters are rewritten.
3. Run **Deploy** with **reload** for `dev-staging` and for `prod-us`, so their Collectors use
   the new ingest password.
4. On the telemetry host, run `sudo systemctl restart rentsync.service`.
5. Check that telemetry from both environments still arrives (quickstart §5).

**OpenObserve metadata database password**: do this rarely. It is the same as the Postgres
procedure, run on the telemetry host against `rentsync-shared-us-openobserve-db-1` with user
`openobserve` and parameter `/rentsync/shared-us/openobserve/db_password`, followed by
`sudo systemctl restart rentsync.service`.

## Replaying failed webhooks on a deployed environment

The admin API is the same as in feature 001 (`specs/001-mock-pms/contracts/openapi.yaml`). Read
the admin token into your own shell from SSM. Never paste it into chat or a file:

```bash
BASE=https://pms-staging.rentsync.org            # or https://pms.rentsync.org
DEPLOYMENT_ID=dev-staging                        # or prod-us
ADMIN_TOKEN="$(aws ssm get-parameter --region us-east-1 --with-decryption \
  --name "/rentsync/$DEPLOYMENT_ID/admin_token" --query Parameter.Value --output text)"

# Find deliveries that ran out of attempts for one client (status: pending, in_flight, succeeded, exhausted)
curl -s "$BASE/admin/deliveries?client_id=<client_id>&status=exhausted" -H "Authorization: Bearer $ADMIN_TOKEN" | jq

# Replay one event to one client (same PMS-Event-Id, with PMS-Replay: true)
curl -s -X POST "$BASE/admin/events/<event_id>/replay" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d '{"client_id":"<client_id>"}'

# Replay every event in a time range, in occurred_at order
curl -s -X POST "$BASE/admin/replays" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"client_id":"<client_id>","from":"2026-10-21T00:00:00Z","to":"2026-10-21T06:00:00Z"}'

unset ADMIN_TOKEN
```

Replays are idempotent from the receiver's point of view, because the event ID is unchanged
(feature 001 research R6). Your own IAM user or SSO role needs `ssm:GetParameter` and
`kms:Decrypt` on that parameter. The console administrator role has both.

## Adding a side-by-side deployment

Every name a deployment owns derives from its DeploymentId (constitution VI), so a new one,
for example `pr-42`, runs next to the others in the same account. No existing deployment's
code or variables change (FR-042). The only edit to shared configuration is one line in the
release role's trust policy, step 2:

1. **HCP:** create workspace `rentsync-pr-42` on `infra/terraform/environment`, tagged
   `rentsync-environment`, like the others in §Bootstrap step 5. Pick its apply method. Add it
   to `rentsync-shared-us`'s remote state sharing list, and set its variables:
   - `deployment_id = pr-42`;
   - `environment` (`staging` for anything that isn't production);
   - `hostname = pms-pr-42.rentsync.org`;
   - a free `private_ip` in `10.40.1.0/24`, such as `10.40.1.42`;
   - `acme_email` and `acme_ca`;
   - a fresh `admin_token`.
2. **AWS IAM:** add `"repo:craig-tx@16706018/RentSync@1427164274:environment:pr-42"` to the `sub` list in the
   `rentsync-github-actions` trust policy
   ([`iam/github-actions-trust.json`](iam/github-actions-trust.json)). Trust uses exact names,
   so a job in an unlisted Environment can't assume the role (security review 2026-10-21).
3. **GitHub:** create Environment `pr-42` with `SITE_URL = https://pms-pr-42.rentsync.org`,
   limited to `main`. Add `pr-42` to the `deployment_id` choice list in
   `.github/workflows/deploy.yml`, which is the only code change.
4. **NameCheap:** add an A record `pms-pr-42` → the workspace's `public_ip` output.
5. Apply, then run **Deploy** for `pr-42` from `main`.

It gets its own host, volume, role, parameters (`/rentsync/pr-42/…`), database
(`mock_pms_pr_42`), Compose project and telemetry label (`deployment.id=pr-42`). It costs
about $17 a month while it exists; Cost Explorer shows it under the `DeploymentId` tag.

**Removing it** follows §Teardown for that one deployment. Afterwards, remove the Environment,
the choice-list entry and the A record.

## Teardown

This stops all costs (quickstart §10). Data volumes are protected (FR-034), so teardown
releases each one from Terraform first. That is the deliberate override; the volumes stay in
AWS until you delete them. Work from the newest deployment to the oldest: environments first,
then `shared-us`, because the environments depend on its network.

1. **Optional:** take a final manual snapshot of each data volume you might want back.
2. For each environment workspace (`rentsync-prod-us`, then `rentsync-dev-staging`, plus any
   side-by-side ones):

   ```bash
   cd infra/terraform/environment
   export TF_WORKSPACE=rentsync-prod-us
   terraform init
   terraform state rm 'module.host.aws_ebs_volume.data'
   ```

   Then, in the HCP UI, open **Settings** → **Destruction and Deletion** → **Queue destroy
   plan**, and confirm.
3. **Empty the image registry**, because ECR refuses to delete a repository that holds
   images (`force_delete = false`):

   ```bash
   repo=shared-us/mock_pms
   aws ecr list-images --region us-east-1 --repository-name "$repo" --query 'imageIds[*]' --output json > /tmp/ids.json
   aws ecr batch-delete-image --region us-east-1 --repository-name "$repo" --image-ids file:///tmp/ids.json
   ```

4. Do the same for `rentsync-shared-us` (`infra/terraform/shared`), with
   `terraform state rm 'module.telemetry_host.aws_ebs_volume.data'`, then queue its destroy.
5. Delete the released data volumes, and any snapshots you don't want:

   ```bash
   aws ec2 describe-volumes --region us-east-1 --filters Name=tag:Project,Values=rentsync \
     --query 'Volumes[].[VolumeId,Tags[?Key==`DeploymentId`]|[0].Value,State]' --output table
   aws ec2 delete-volume --region us-east-1 --volume-id vol-…
   aws ec2 describe-snapshots --region us-east-1 --owner-ids self --filters Name=tag:Project,Values=rentsync \
     --query 'Snapshots[].[SnapshotId,StartTime]' --output table
   aws ec2 delete-snapshot --region us-east-1 --snapshot-id snap-…
   ```

6. Delete the NameCheap A records.
7. If you're leaving for good, also delete the bootstrap roles, policies and OIDC providers
   (§Bootstrap steps 1–2), and the HCP workspaces.

Next day: Cost Explorer, grouped by `DeploymentId`, should show no new charges.
