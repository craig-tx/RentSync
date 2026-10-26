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

This one-time setup should take under an hour (FR-006). Three scripts and two AWS CLI commands
do all of it, so you don't click through any console. Each script prints a plan and changes
nothing until you rerun it with `--apply`. Each is safe to rerun. The setup creates no AWS access
keys, and no credential ever goes into chat, the repository, or a terminal history. Afterwards,
every change goes through HCP Terraform runs. Note the start time; T053 records how long it took.

| Step | What | Where it runs | When |
|---|---|---|---|
| 1 | `bootstrap-iam.sh`: AWS OIDC providers and roles | AWS CloudShell | first |
| 2 | AWS CLI: look up the AMI | AWS CloudShell | after step 1 |
| 3 | `bootstrap-hcp.rb`: HCP Terraform project, workspaces and variables | PowerShell, your machine | after step 2 |
| 4 | `bootstrap-github.sh`: GitHub variables, Environments and secret scanning | Git Bash, your machine | after step 1; rerun after T054 and at T074 |
| 5 | AWS CLI: activate the `DeploymentId` cost allocation tag | AWS CloudShell | about a day after the first apply |

You need an AWS account (AWS region `us-east-1`), owner access to the HCP Terraform
organization `craig-personal`, admin access to `craig-tx/RentSync` on GitHub, and the NameCheap
account for `rentsync.org`. On your machine, you need Ruby, Terraform and the `gh` CLI.

### 1. AWS: OIDC providers and bootstrap roles

[`infra/bootstrap/bootstrap-iam.sh`](../../infra/bootstrap/bootstrap-iam.sh) creates the two OIDC
providers and four roles, using the policy documents in [`iam/`](iam/)
(contracts/bootstrap-iam.md). CloudShell acts as your console session, so no access key is
created. The script reads the AWS account ID from that session, writes filled-in copies of the
documents to the gitignored `.bootstrap/iam/`, and validates each one with IAM Access Analyzer.
Any error or security warning stops it before it changes anything.

1. Sign in to the AWS console as an administrator, switch to `us-east-1`, and open
   **CloudShell** from the top bar.
2. Clone the repository:

   ```bash
   git clone https://github.com/craig-tx/RentSync.git && cd RentSync
   ```

3. Print the plan, and review the `+ aws …` lines:

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh
   ```

4. Make the changes:

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh --apply
   ```

The script ends by printing the role ARNs. You don't need to copy them: steps 3 and 4 build them
from the AWS account ID.

### 2. AWS: look up the AMI

In the same CloudShell session, print the current Amazon Linux 2023 arm64 AMI ID. Step 3 takes it
as `--ami`:

```bash
aws ssm get-parameter --region us-east-1 \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text
```

The AMI is pinned on purpose: changing `ami_id` later replaces every host (research R4).

### 3. HCP Terraform: project, workspaces and variables

[`infra/bootstrap/bootstrap-hcp.rb`](../../infra/bootstrap/bootstrap-hcp.rb) does this through the
HCP Terraform API:
- the `RentSync` project, and the `rentsync-aws` variable set holding the
  `rentsync-hcp-terraform` role ARN;
- the three workspaces, tracking `main`, with their apply methods and tags;
- remote state sharing from `rentsync-shared-us`;
- every workspace variable in contracts/workspace-variables.md.

It needs only Ruby, with no gems.
- **Secrets:** each `admin_token` is generated inside the script, a different one per
  environment, and sent straight to HCP Terraform as a sensitive variable. The OpenObserve root
  password is asked for twice, without echo, and checked against Terraform's rule before anything
  changes.
- **Reruns:** it restores workspace settings that drifted, but never changes a variable that
  exists. It reports one whose value differs, because you change those on purpose later
  (`acme_ca`, `ami_id`, rotations).

Run it in PowerShell or Windows Terminal. Git Bash's terminal can't hide the password prompt.

1. Sign in to HCP Terraform once. `terraform login` opens the browser and saves a token in your
   user profile, where the script reads it. The token is never printed:

   ```powershell
   terraform login
   ```

2. Print the plan:

   ```powershell
   ruby infra/bootstrap/bootstrap-hcp.rb --aws-account <AWS account ID> --ami <AMI from step 2> `
     --acme-email <contact> --openobserve-email <sign-in email> --budget-email <alert recipient>
   ```

3. Add `--apply` to make the changes. Other options:
   - `--branch` changes the branch the workspaces track (default `main`);
   - `--health-assessments` turns on drift detection, if your HCP Terraform plan includes it.

### 4. GitHub: variables, Environments and secret scanning

[`infra/bootstrap/bootstrap-github.sh`](../../infra/bootstrap/bootstrap-github.sh) does this
through the GitHub API, with the `gh` CLI:
- the repository variables `AWS_BUILD_ROLE_ARN`, `AWS_ROLE_ARN` and `AWS_REGION`;
- the Environments `dev-staging` and `prod-us`. Each allows only branch `main`, because the
  release roles trust these Environments by name;
- each Environment's `SITE_URL`, the only place deployment URLs are recorded;
- the `prod-us` `AWS_ROLE_ARN` override, which points production jobs at
  `rentsync-github-actions-prod`;
- secret scanning and push protection (SC-004).

It sets only non-secret values. On a rerun, a value that differs is set again, an extra deployment
branch is removed, and an existing reviewer is kept.

You run it three times. Each run passes the earlier flags again and adds one:

| When | Flags | What the run adds |
|---|---|---|
| Now | `--aws-account <AWS account ID>` | everything in the list above |
| After the first `rentsync-shared-us` apply (T054) | add `--ecr-repository-url <URL>` | `ECR_REPOSITORY_URL`, from that workspace's `ecr_repository_url` output (HCP Terraform → `rentsync-shared-us` → **Outputs**). Releases are skipped until it is set. |
| Task T074 | add `--prod-reviewer <your GitHub username>` | you, as the `prod-us` required reviewer |

1. Sign in to GitHub once, if you haven't: `gh auth login`.
2. In Git Bash, print the plan:

   ```bash
   bash infra/bootstrap/bootstrap-github.sh --aws-account <AWS account ID>
   ```

3. Add `--apply` to make the changes.

### 5. AWS: activate the cost allocation tag

AWS can only activate a tag after its billing data has seen it, which happens about a day after
the first apply. Then, in CloudShell:

```bash
aws ce list-cost-allocation-tags --region us-east-1 --tag-keys DeploymentId \
  --query 'CostAllocationTags[].Status' --output text
aws ce update-cost-allocation-tags-status --region us-east-1 \
  --cost-allocation-tags-status TagKey=DeploymentId,Status=Active
```

If the first command prints nothing, AWS hasn't seen the tag yet; try again later. Once active,
Cost Explorer can group spend by deployment (constitution VI).

### If a step fails

- **`create-role` fails with "Invalid principal" (step 1):** the OIDC providers were created
  moments before, and IAM hasn't caught up. Wait a few seconds and rerun `--apply`.
- **Step 1 says a policy exists and was not changed:** an existing policy is never changed
  automatically. Compare it with the file in `.bootstrap/iam/`, and if the file is right, run the
  `create-policy-version` command the script prints.
- **Step 3 says it found no GitHub connection:** HCP Terraform isn't connected to GitHub yet.
  Connect it once, in HCP Terraform: **New** → **Workspace** → **Version control workflow** →
  **GitHub**. Authorize and install the app for `craig-tx`, cancel before creating the workspace,
  and rerun the script.
- **Step 3 reports a variable whose value differs:** that's expected after a deliberate change,
  such as the switch to production certificates. To change a variable, edit it in the workspace.

### Values

Every value below is non-secret, but don't write them into this file: the repository is public
and never names an AWS account ID. You pass each one to a script, and the script sets it in the
place shown. Those places are the record.

| Value | Where it comes from | Passed to | Ends up in |
|---|---|---|---|
| AWS account ID | AWS console, top right | `bootstrap-hcp.rb` and `bootstrap-github.sh` (`--aws-account`); step 1 reads it itself | the role ARNs below |
| AWS region | `us-east-1` | fixed in the scripts | variable defaults; GitHub `AWS_REGION` |
| HCP Terraform organization | `craig-personal` | fixed in `bootstrap-hcp.rb` | `versions.tf` (`cloud` block) |
| `rentsync-hcp-terraform` role ARN | built from the AWS account ID | `bootstrap-hcp.rb` | variable set `TFC_AWS_RUN_ROLE_ARN` |
| `rentsync-github-build` role ARN | built from the AWS account ID | `bootstrap-github.sh` | GitHub repository variable `AWS_BUILD_ROLE_ARN` |
| `rentsync-github-actions` role ARN | built from the AWS account ID | `bootstrap-github.sh` | GitHub repository variable `AWS_ROLE_ARN` |
| `rentsync-github-actions-prod` role ARN | built from the AWS account ID | `bootstrap-github.sh` | GitHub `prod-us` Environment variable `AWS_ROLE_ARN` |
| AMI ID | step 2 | `bootstrap-hcp.rb --ami` | `rentsync-shared-us` `ami_id` |
| ECR repository URL | `rentsync-shared-us` output `ecr_repository_url` | `bootstrap-github.sh --ecr-repository-url` | GitHub `ECR_REPOSITORY_URL` |

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
   Releases are skipped until `ECR_REPOSITORY_URL` is set (§Bootstrap step 4, after T054).
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
first initializes, so change the password on the OpenObserve root user first:

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
for example `pr-42`, runs next to the others in the same AWS account. No existing deployment's
code or variables change (FR-042). The only edit to shared configuration is one line in the
release role's trust policy, step 2:

1. **HCP:** create workspace `rentsync-pr-42` on `infra/terraform/environment`, tagged
   `rentsync-environment`, with the settings `bootstrap-hcp.rb` gives the other environment
   workspaces (§Bootstrap step 3). Pick its apply method. Add it
   to `rentsync-shared-us`'s remote state sharing list, and set its variables:
   - `deployment_id = pr-42`;
   - `environment` (`staging` for anything that isn't production);
   - `hostname = pms-pr-42.rentsync.org`;
   - a free `private_ip` in `10.40.1.0/24`, such as `10.40.1.42`;
   - `acme_email` and `acme_ca`;
   - a fresh `admin_token`.
2. **AWS IAM:** add `"repo:craig-tx@16706018/RentSync@1427164274:environment:pr-42"` to the `sub` list in the
   `rentsync-github-actions` trust policy
   ([`iam/github-actions-trust.json`](iam/github-actions-trust.json)). Merge that, then rerun
   `bootstrap-iam.sh --apply` in CloudShell, which updates the role's trust policy. Trust uses
   exact names, so a job in an unlisted Environment can't assume the role (security review
   2026-10-21).
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
   (§Bootstrap step 1), and the HCP workspaces.

Next day: Cost Explorer, grouped by `DeploymentId`, should show no new charges.
