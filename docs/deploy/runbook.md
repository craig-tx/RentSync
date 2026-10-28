# RentSync deployment runbook

Operator procedures for deploying the mock PMS to AWS (feature 002). Design and rationale:
[specs/002-aws-deployment/](../../specs/002-aws-deployment/). End-to-end validation:
[quickstart.md](../../specs/002-aws-deployment/quickstart.md).

Nothing here is specific to one operator. Your own values (AWS account and region, HCP Terraform
organization, GitHub repository, domain, contact emails) live in `.bootstrap/settings.env`.
Bootstrap step 0 writes that file, and it is never committed. In this runbook, `<domain>` means
your domain.

- **The bootstrap scripts read the file themselves.** You never need to load it to run them.
- **Commands you type by hand** (`curl`, and the `aws` and `terraform` one-offs in later
  sections) use its values as `$RENTSYNC_…` variables. Each of those code blocks starts with
  `source .bootstrap/settings.env`, which loads them into your shell; run it from the repository
  root. Running it again is harmless.
- **Where to run them:** `aws` commands in **CloudShell**, because your machine has no AWS
  credentials; everything else on **your machine**, in Git Bash on Windows or Terminal on macOS
  (`source` is a bash command, so not in PowerShell or Command Prompt). Bootstrap step 1 copies
  every setting into CloudShell, so the same blocks work in both. After rerunning step 0, paste
  its CloudShell block again to keep the copy current.

Deployments (constitution Principle VI, DeploymentId):

| DeploymentId | Serves | HCP Terraform workspace | URL |
|---|---|---|---|
| `shared-us` | VPC, ECR, telemetry, backups, budget | `rentsync-shared-us` | `https://telemetry.<domain>` |
| `dev-staging` | staging | `rentsync-dev-staging` | `https://pms-staging.<domain>` |
| `prod-us` | production | `rentsync-prod-us` | `https://pms.<domain>` |

## Bootstrap

This one-time setup should take under an hour (FR-006). Four scripts and one AWS CLI command do
all of it, so you don't click through any console. Each script except step 0 prints a plan and
changes nothing until you rerun it with `--apply`, and each is safe to rerun. The setup creates no
AWS access keys, and no credential ever goes into chat, the repository, or a terminal history.
Afterwards, every change goes through HCP Terraform runs. Every step can be reversed with
§Bootstrap teardown. Note the start time; T053 records how long it took.

| Step | What | Where it runs | When |
|---|---|---|---|
| 0 | `bootstrap-init.sh`: asks for your settings and saves them | your machine | first |
| 1 | `bootstrap-iam.sh`: AWS OIDC providers and roles, and the AMI ID for your settings | AWS CloudShell | after step 0 |
| 2 | `bootstrap-hcp.rb`: HCP Terraform project, workspaces and variables | your machine | after step 1 |
| 3 | `bootstrap-github.sh`: GitHub variables, Environments and secret scanning | your machine | after step 1; rerun after T054 and at T074 |
| 4 | AWS CLI: activate the `DeploymentId` cost allocation tag | AWS CloudShell | about a day after the first apply |

You need:
- an AWS account you can sign in to as an administrator;
- an HCP Terraform organization you own;
- admin access to your copy of this repository on GitHub;
- a domain, and access to its DNS records;
- on your machine: bash 4.4 or later, Ruby 3 or later, Terraform, the `gh` CLI, and `jq`, which
  formats JSON in the checks after bootstrap (setup below).

**On macOS**, Apple's built-in bash (3.2) and Ruby (2.6) are too old. Install current ones with
[Homebrew](https://brew.sh), then open a new Terminal so `bash` and `ruby` resolve to them:

```bash
brew install bash ruby gh jq hashicorp/tap/terraform
bash --version   # 5.x
ruby --version   # 3.x
```

Homebrew's Ruby is keg-only: if `ruby --version` still says 2.6, add
`export PATH="$(brew --prefix ruby)/bin:$PATH"` to `~/.zshrc` and open a new Terminal. The bash
scripts check their bash version and stop with this advice if it is too old. Every command below
runs in Terminal.

**On Windows**, install Git for Windows (for Git Bash), Ruby, Terraform, `gh` and `jq`, for
example with winget in PowerShell, then open a new Git Bash window so it finds them:

```powershell
winget install Git.Git RubyInstallerTeam.Ruby.3.3 Hashicorp.Terraform GitHub.cli jqlang.jq
```

Two things differ from macOS:
- **Use Git Bash, not WSL, for the bash scripts.** A bare `bash` typed in PowerShell or Command
  Prompt starts WSL, which can't see the Windows `gh`. Open a Git Bash window, or call it by path:
  in Command Prompt, `"C:\Program Files\Git\bin\bash.exe" infra/bootstrap/<script> …`, and in
  PowerShell, prefix that with `&`.
- **Use PowerShell or Windows Terminal for `bootstrap-hcp.rb`.** Git Bash's terminal can't hide
  its password prompt.

### 0. Your settings

[`infra/bootstrap/bootstrap-init.sh`](../../infra/bootstrap/bootstrap-init.sh) asks for each
setting and writes `.bootstrap/settings.env` (gitignored). The other scripts read it from there.
It asks for:
- your AWS account ID, AWS region and availability zone;
- your HCP Terraform organization and GitHub repository;
- your domain;
- the Let's Encrypt, OpenObserve and AWS budget emails;
- the AMI ID. Leave it blank: step 1 looks it up and prints the command that saves it.

It also reads your repository's OIDC subject format from GitHub, which the IAM trust policies
need. It asks for nothing secret: step 2 handles the password and tokens. Rerun it any time; Enter
keeps each current value.

1. Sign in to GitHub once, if you haven't: `gh auth login`.
2. From the repository root:

   ```bash
   bash infra/bootstrap/bootstrap-init.sh
   ```

It ends by printing a block to paste into CloudShell in step 1.

### 1. AWS: OIDC providers and bootstrap roles

[`infra/bootstrap/bootstrap-iam.sh`](../../infra/bootstrap/bootstrap-iam.sh) creates the two OIDC
providers and four roles, from the policy documents in [`iam/`](iam/)
(contracts/bootstrap-iam.md). CloudShell acts as your console session, so no access key is
created.
- **Templates:** the documents hold placeholders such as `<aws-account-id>` and
  `<github-subject>`. The script fills them from the settings into the gitignored
  `.bootstrap/iam/`.
- **Checks before any change:** it stops if CloudShell is signed in to a different AWS account
  than the settings name. It validates each document with IAM Access Analyzer, and stops on any
  error or security warning.

1. Sign in to the AWS console as an administrator, switch to your AWS region, and open
   **CloudShell** from the top bar.
2. Paste the block that step 0 printed. It clones your repository (or updates an existing clone),
   enters it, and writes a copy of your settings there. CloudShell keeps your home directory
   between sessions, so later CloudShell commands in this runbook find it too.
3. Print the plan, and review the `+ aws …` lines:

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh
   ```

4. Make the changes:

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh --apply
   ```

The script ends by printing two things:
- **The role ARNs.** You don't need to copy them: steps 2 and 3 build them from the settings.
- **The AMI ID**, the latest Amazon Linux 2023 arm64 image in your AWS region. It comes from
  AWS's public parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`,
  so there is nothing to check by eye. The script prints the command that saves it. Back on your
  machine, run that command, which changes only the AMI ID in your settings:

  ```bash
  bash infra/bootstrap/bootstrap-init.sh --ami <the AMI ID it printed>
  ```

  The AMI is pinned on purpose: changing `ami_id` later replaces every host (research R4). The
  `rentsync-shared-us` plan shows it before you confirm the first apply.

### 2. HCP Terraform: project, workspaces and variables

[`infra/bootstrap/bootstrap-hcp.rb`](../../infra/bootstrap/bootstrap-hcp.rb) does this through the
HCP Terraform API:
- the `RentSync` project, and the `rentsync-aws` variable set holding the
  `rentsync-hcp-terraform` role ARN and `TF_CLOUD_ORGANIZATION`;
- the three workspaces, tracking `main`, with their apply methods and tags;
- remote state sharing from `rentsync-shared-us`;
- every workspace variable in contracts/workspace-variables.md, including the AWS region, the
  zone and the hostnames from your settings.

It needs only Ruby 3 or later, with no gems. On Windows, run it in PowerShell (see above).
- **Secrets:** each `admin_token` is generated inside the script, a different one per
  environment, and sent straight to HCP Terraform as a sensitive variable. The OpenObserve root
  password is asked for twice, without echo, and checked against Terraform's rule before anything
  changes.
- **Reruns:** rerun it any time; it treats workspace *settings* and *variables* differently.
  - **Settings** (working directory, apply method, Terraform version, trigger patterns, the
    GitHub connection) are part of the design, so a rerun restores any that drifted.
  - **Variables** are set once. A rerun adds missing ones but **never changes one that exists**;
    it prints `… is "<current>", not "<first value>"; not changed`. Some variables are meant to
    change after bootstrap, and resetting them would undo that work. For example, resetting
    `acme_ca` would put every host back on untrusted staging certificates.

    | Variable | Changed later by |
    |---|---|
    | `acme_ca` | §DNS, the switch to production certificates |
    | `ami_id` | §Monthly OS patching |
    | `instance_type`, `telemetry_instance_type` | §Changing a host's instance type |
    | `admin_token`, `openobserve_root_password`, `postgres_password_version`, `openobserve_db_password_version` and their `*_version` counters | §Secret rotation |
    | `data_snapshot_id` | §Backup restore |

    To change any other value bootstrap set, such as a hostname after a domain change, edit
    the variable in the workspace yourself; a rerun won't. Each variable's role is in
    contracts/workspace-variables.md.

1. Sign in to HCP Terraform once. `terraform login` opens the browser and saves a token in your
   user profile, where the script reads it. The token is never printed:

   ```bash
   terraform login
   ```

2. Print the plan:

   ```bash
   ruby infra/bootstrap/bootstrap-hcp.rb
   ```

3. Add `--apply` to make the changes. Options:
   - `--ami`, `--aws-account` and the email flags override the settings;
   - `--branch` changes the branch the workspaces track (default `main`);
   - `--health-assessments` turns on drift detection, if your HCP Terraform plan includes it.

### 3. GitHub: variables, Environments and secret scanning

[`infra/bootstrap/bootstrap-github.sh`](../../infra/bootstrap/bootstrap-github.sh) does this
through the GitHub API, with the `gh` CLI:
- the repository variables `AWS_BUILD_ROLE_ARN`, `AWS_ROLE_ARN` and `AWS_REGION`;
- the Environments `dev-staging` and `prod-us`. Each allows only branch `main`, because the
  release roles trust these Environments by name;
- each Environment's `SITE_URL` (`https://pms-staging.<domain>` and `https://pms.<domain>`), the
  only place deployment URLs are recorded;
- the `prod-us` `AWS_ROLE_ARN` override, which points production jobs at
  `rentsync-github-actions-prod`;
- secret scanning and push protection (SC-004).

It sets only non-secret values. On a rerun, a value that differs is set again, an extra deployment
branch is removed, and an existing reviewer is kept.

You run it three times. Each later run adds one flag:

| When | Flags | What the run adds |
|---|---|---|
| Now | none | everything in the list above |
| After the first `rentsync-shared-us` apply (§First apply, step 2) | `--ecr-repository-url <URL>` | `ECR_REPOSITORY_URL`, from that workspace's `ecr_repository_url` output (HCP Terraform → `rentsync-shared-us` → **Outputs**). Releases are skipped until it is set. |
| Task T074 | `--prod-reviewer <your GitHub username>` | you, as the `prod-us` required reviewer |

1. Print the plan:

   ```bash
   bash infra/bootstrap/bootstrap-github.sh
   ```

2. Add `--apply` to make the changes.

### 4. AWS: activate the cost allocation tag

AWS can only activate a tag after its billing data has seen it, which happens about a day after
the first apply (§First apply). Then, in CloudShell, from the repository directory:

```bash
source .bootstrap/settings.env
aws ce list-cost-allocation-tags --region "$RENTSYNC_AWS_REGION" --tag-keys DeploymentId \
  --query 'CostAllocationTags[].Status' --output text
aws ce update-cost-allocation-tags-status --region "$RENTSYNC_AWS_REGION" \
  --cost-allocation-tags-status TagKey=DeploymentId,Status=Active
```

If the first command prints nothing, AWS hasn't seen the tag yet; try again later. Once active,
Cost Explorer can group spend by deployment (constitution VI).

### If a step fails

- **A script says there are no settings:** run step 0. In CloudShell, paste the block step 0
  printed.
- **Step 1 says the signed-in AWS account differs from the settings:** you're in the wrong AWS
  account, or the settings are wrong. Fix whichever it is, then rerun step 0 and repaste the
  block.
- **`create-role` fails with "Invalid principal" (step 1):** the OIDC providers were created
  moments before, and IAM hasn't caught up. Wait a few seconds and rerun `--apply`.
- **Step 1 says a policy exists and was not changed:** an existing policy is never changed
  automatically. Compare it with the file in `.bootstrap/iam/`, and if the file is right, run the
  `create-policy-version` command the script prints.
- **Step 1 warns that it could not read the AMI:** the IAM changes are unaffected. Rerun the
  plan (`bash infra/bootstrap/bootstrap-iam.sh`), which changes nothing and prints the AMI again.
- **Step 2 says it found no GitHub connection:** HCP Terraform isn't connected to GitHub yet.
  Connect it once, in HCP Terraform: **New** → **Workspace** → **Version control workflow** →
  **GitHub**. Authorize and install the app for your GitHub account, cancel before creating the
  workspace, and rerun the script.
- **Step 2 reports a variable whose value differs:** that's expected after a deliberate change,
  such as the switch to production certificates. To change a variable, edit it in the workspace.
- **A script says `gh` was not found:** install it (see above). On Windows, you're probably in
  WSL; use Git Bash.
- **A script says it needs bash 4.4 or later:** on macOS, `brew install bash` and open a new
  Terminal (see above).

### Where each setting ends up

Every value is non-secret, but none of them is written into the repository. The settings file is
gitignored, and the places in the last column are the record.

| Setting | Read by | Ends up in |
|---|---|---|
| AWS account ID | steps 1, 2 and 3 | the role ARNs: the variable set's `TFC_AWS_RUN_ROLE_ARN`, and GitHub's `AWS_BUILD_ROLE_ARN` and `AWS_ROLE_ARN` (repository and `prod-us`) |
| AWS region | steps 1, 2 and 3 | the IAM documents, the AMI lookup, the workspaces' `region`, and GitHub's `AWS_REGION` |
| AWS availability zone | step 2 | `rentsync-shared-us` `availability_zone` |
| HCP Terraform organization | steps 1 and 2 | the `rentsync-hcp-terraform` trust, `TF_CLOUD_ORGANIZATION`, and the environment workspaces' `hcp_organization` |
| GitHub repository and OIDC subject | steps 1, 2 and 3 | the GitHub role trusts, the workspaces' VCS connection, and the target of step 3 |
| Domain | steps 2 and 3 | the workspaces' `hostname` and `telemetry_hostname`, and GitHub's `SITE_URL`s |
| Emails | step 2 | `acme_email`, `openobserve_root_email`, `budget_email` |
| AMI ID (printed by step 1) | step 2 | `rentsync-shared-us` `ami_id` |
| ECR repository URL (not a setting) | step 3, `--ecr-repository-url` | GitHub `ECR_REPOSITORY_URL` |

**Local Terraform commands** (teardown, backup restore) need the organization too, because the
`cloud` blocks don't name it. The code blocks that run them set `TF_CLOUD_ORGANIZATION` from
the settings.

Next: §First apply.

## First apply

This creates the AWS resources: the three VPCs and their peering, the three hosts with their
Elastic IPs and data volumes, the image registry, the audit trail and log bucket, backups and the
budget. AWS charges start here, at about $43 a month (README). Bootstrap only created the
workspaces; none of them has run yet.

Apply in this order, because each environment reads `rentsync-shared-us`'s outputs (its VPC,
AMI and telemetry endpoint) and peers with its VPC. An environment planned before the shared
apply fails, because those outputs don't exist yet. The hosts come up with Let's Encrypt's
**staging** certificates (`acme_ca`, set by bootstrap step 2), which avoids its rate limits
while DNS is new; §DNS switches them to production afterwards.

Note the time when you start the first apply; T054 records how long the three hosts take to
serve HTTPS (SC-001: 60 minutes, not counting DNS propagation).

1. **`rentsync-shared-us`** (HCP Terraform → project `RentSync` → the workspace → **New run** →
   **Plan and apply** → **Start**). Review the plan: every resource is a create, every name
   carries `shared-us`, and the host uses the AMI ID from your settings. Then **Confirm &
   apply**.
2. **Give GitHub the image registry.** In the workspace's **Outputs**, copy
   `ecr_repository_url`, and on your machine run:

   ```bash
   bash infra/bootstrap/bootstrap-github.sh --ecr-repository-url <ecr_repository_url>
   bash infra/bootstrap/bootstrap-github.sh --ecr-repository-url <ecr_repository_url> --apply
   ```

3. **`rentsync-dev-staging`**: start a run the same way. This workspace applies automatically,
   so review the plan as it goes; there is no confirm step.
4. **`rentsync-prod-us`**: start a run, review the plan, and **Confirm & apply**.

Each host boots with Caddy only, and answers `no image deployed yet` until §First deploy. Each
workspace's **Outputs** now show the addresses §DNS needs.

**If a run fails:**
- **The plan can't assume the AWS role:** the `rentsync-aws` variable set must be attached to
  the project (bootstrap step 2), and the `rentsync-hcp-terraform` role must exist (step 1).
  Rerun those steps' plans; they report what is missing.
- **An environment can't read the shared state:** `rentsync-shared-us` hasn't been applied, or
  isn't sharing its state with that workspace. Rerun bootstrap step 2's plan.
- **An apply stops partway:** start another run. Terraform keeps what was created and plans only
  the rest.

Next: §DNS, then §First deploy.

## DNS

Terraform does not manage DNS (FR-021). After §First apply, create three A records for
`<domain>` at your DNS provider:

| Type | Host | Value (workspace output) | TTL |
|---|---|---|---|
| A Record | `telemetry` | `rentsync-shared-us` → `telemetry_public_ip` | 5 min |
| A Record | `pms-staging` | `rentsync-dev-staging` → `public_ip` | 5 min |
| A Record | `pms` | `rentsync-prod-us` → `public_ip` | 5 min |

The workspace outputs are the record of each address; don't copy them into this file. They never
change, because the Elastic IPs survive host replacement.

Check that each record resolves, on your machine (Git Bash on Windows, Terminal on macOS) from
the repository root. CloudShell's copy of the settings has no domain. The check asks Google's
public DNS over HTTPS, with `curl`, because public DNS is what Let's Encrypt and visitors see;
your local network's resolver may cache old answers or add its own search domain:

```bash
source .bootstrap/settings.env
for h in telemetry pms-staging pms; do
  ip="$(curl -s "https://dns.google/resolve?name=$h.$RENTSYNC_DOMAIN&type=A" |
    grep -o '"type":1,"TTL":[0-9]*,"data":"[^"]*"' | cut -d'"' -f8 | tr '\n' ' ')"
  echo "$h.$RENTSYNC_DOMAIN -> ${ip:-not resolving yet}"
done
```

Each line should show the IP from the matching workspace output. `not resolving yet` means the
record is missing or hasn't propagated; new records usually appear within minutes.

**Switching to production certificates**: hosts first come up with `acme_ca` pointing at the
Let's Encrypt staging endpoint. That avoids rate limits while DNS propagates, but its
certificates are not publicly trusted. Once every record resolves to its IP:

1. Set `acme_ca` to `https://acme-v02.api.letsencrypt.org/directory` in all three workspaces.
2. Apply `rentsync-shared-us` (confirm), then `rentsync-dev-staging`, then `rentsync-prod-us`
   (confirm). Changing the host configuration replaces each host. Its address and data are
   kept (research R6).
3. Check each certificate, on your machine (Git Bash on Windows, Terminal on macOS):

   ```bash
   source .bootstrap/settings.env
   for h in telemetry pms-staging pms; do
     printf '%s: ' "$h.$RENTSYNC_DOMAIN"
     curl -sv -o /dev/null "https://$h.$RENTSYNC_DOMAIN/" 2>&1 |
       grep -E 'issuer:|verify ok|certificate problem' | sed 's/^\* *//' | tr '\n' ' '
     echo
   done
   ```

   Each line should show `O=Let's Encrypt` with an issuer such as `CN=YE1` or `CN=E7`, and
   `SSL certificate verify ok`. A staging certificate's issuer starts with `(STAGING)`, and
   curl reports a certificate problem instead.

After bring-up, set the TTLs back to **Automatic**. The records never change again, because
the Elastic IPs survive host replacement.

## First deploy

This assumes Bootstrap, First apply and DNS are done, **including the switch to Let's Encrypt
production certificates** (§DNS), so every workspace has been applied with the production
`acme_ca`. The
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
   source .bootstrap/settings.env
   curl -s "https://pms-staging.$RENTSYNC_DOMAIN/healthz" | jq
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
   Releases are skipped until `ECR_REPOSITORY_URL` is set (§Bootstrap step 3, after T054).
2. **`deploy-dev-staging`** runs `rentsync-deploy <sha>` on the `dev-staging` host, then checks
   `https://pms-staging.<domain>/healthz` for `status=ok`, `version=<sha>` and
   `deployment_id=dev-staging`. The target is 15 minutes from merge (SC-005).
3. **`deploy-prod-us`** waits for you. Open the run → **Review deployments** → `prod-us` →
   **Approve and deploy**. It deploys the **same** SHA (FR-027) and checks
   `https://pms.<domain>/healthz`. The target is 10 minutes after approval.

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
source .bootstrap/settings.env
curl -s "https://pms.$RENTSYNC_DOMAIN/healthz" | jq -r .version   # the previous SHA
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

## Changing a host's instance type

The environment hosts are `t4g.micro` (1 GiB) and the telemetry host is `t4g.small` (2 GiB).
The environment hosts measured about 700–750 MiB at peak (research R4), and every host has a
1 GiB swap file for short peaks. Don't go below `t4g.micro`, and keep the telemetry host on
`t4g.small`: OpenObserve alone peaked near 950 MiB.

The size comes from the variable's default in the Terraform root (`instance_type` in
`infra/terraform/environment/variables.tf`, `telemetry_instance_type` in
`infra/terraform/shared/variables.tf`). Changing a default changes every workspace that hasn't
set the variable. To size one workspace differently, set the variable in that workspace.
Either way the next apply replaces the host as in §Host replacement; its address and data are
kept.

**Check memory** after a deploy, the busiest moment for memory. In a session on the host
(`aws ssm start-session --target <instance_id>`):

```bash
free -m                          # "available" should stay above ~100 MiB
swapon --show                    # swap in use; a little after a deploy is normal
sudo docker stats --no-stream    # memory per container
```

**Going back up**: if swap use keeps growing, or `/healthz` gets slow, set `instance_type` to
`t4g.small` in that environment's workspace and start a run.

## Monthly OS patching (AMI update)

Hosts are immutable and the AMI is pinned (research R4), so a host gets no operating system
security patches until its AMI changes. Patch by replacing every host with the latest Amazon
Linux 2023 AMI, **once a month**, and sooner for a critical advisory. Each host keeps its
address, data and certificates, as in §Host replacement. Each one is down for a few minutes.

1. Look up the current AMI, in CloudShell or anywhere with AWS CLI access:

   ```bash
   source .bootstrap/settings.env
   aws ssm get-parameter --region "$RENTSYNC_AWS_REGION" \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
     --query Parameter.Value --output text
   ```

   If it equals the `ami_id` in `rentsync-shared-us`, there's nothing to do.
2. In `rentsync-shared-us`, set `ami_id` to the new ID and apply (confirm). This replaces the
   telemetry host. The environments read `ami_id` from the shared outputs.
3. Start a run in `rentsync-dev-staging`. It plans a replacement of the staging host and
   applies automatically. Check `https://pms-staging.<domain>/healthz`.
4. Start a run in `rentsync-prod-us` and confirm it. Check `https://pms.<domain>/healthz`.
5. Save the new AMI ID in your settings with `bash infra/bootstrap/bootstrap-init.sh --ami <id>`.
   Record the date and AMI ID in `docs/ai-build-log.md`.

## Audit logs

The shared deployment records, into one private, encrypted S3 bucket
(`rentsync-shared-us-logs-<AWS account ID>`, kept for 90 days):
- **CloudTrail:** every API call in the AWS account, in every region, with log file validation,
  so tampering with a delivered log is detectable. Look up recent events in the console under
  CloudTrail → **Event history**, or read the files under `AWSLogs/<AWS account ID>/CloudTrail/`.
- **VPC Flow Logs:** accepted and rejected traffic for each deployment's VPC, under
  `vpc-flow-logs/rentsync-<deployment_id>/`. For example, to see what reached production's VPC
  today:

  ```bash
  source .bootstrap/settings.env
  aws s3 ls --recursive "s3://rentsync-shared-us-logs-$RENTSYNC_AWS_ACCOUNT_ID/vpc-flow-logs/rentsync-prod-us/" | tail
  ```

To keep logs beyond 90 days or past a teardown, copy them out first.

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
   source .bootstrap/settings.env
   aws ec2 describe-snapshots --region "$RENTSYNC_AWS_REGION" --owner-ids self \
     --filters Name=tag:DeploymentId,Values=dev-staging \
     --query 'reverse(sort_by(Snapshots,&StartTime))[].[SnapshotId,StartTime,VolumeSize]' --output table
   ```

2. **Release the current volume from Terraform's management** (the override). It stays in
   AWS, attached and untouched:

   ```bash
   source .bootstrap/settings.env
   cd infra/terraform/environment
   export TF_CLOUD_ORGANIZATION="$RENTSYNC_HCP_ORG" TF_WORKSPACE=rentsync-dev-staging
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
   source .bootstrap/settings.env
   aws ec2 describe-volumes --region "$RENTSYNC_AWS_REGION" \
     --filters Name=tag:DeploymentId,Values=dev-staging Name=status,Values=available \
     --query 'Volumes[].[VolumeId,CreateTime]' --output table
   aws ec2 delete-volume --region "$RENTSYNC_AWS_REGION" --volume-id vol-…
   ```

## Secret rotation

A new value goes into HCP (or a version bump generates one). The apply writes it to SSM through
a write-only argument, so it never appears in state or logs. Then the containers pick it up
with a **reload**. Run **Deploy** with the deployment, `image_tag` empty, and **reload**
ticked. Re-deploying the same SHA would be a no-op.

To confirm that no secret reached HCP state or run logs (SC-004), run this on your machine. It
only reads, and prints where a secret appears, never the value:

```bash
ruby infra/bootstrap/audit-hcp-secrets.rb                               # admin tokens by value (rentsync role)
ruby infra/bootstrap/audit-hcp-secrets.rb --aws-profile rentsync-login  # every secret by value
```

Secrets the profile can't decrypt are still checked by attribute (a SecureString value or a
random password in state fails). Exit 0 is PASS, 1 is a finding, 2 is an error.

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
   . /etc/rentsync/host.env   # the host's non-secret settings, including AWS_REGION
   NEW="$(aws ssm get-parameter --region "$AWS_REGION" --with-decryption \
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

1. Sign in to `https://telemetry.<domain>` → **IAM** → **Users** → the root user →
   **Change password**, and set the new value.
2. In `rentsync-shared-us`, set `openobserve_root_password` to the same value and increase
   `openobserve_root_password_version` by 1. Apply (confirm). Both the root and ingest
   parameters are rewritten.
3. Run **Deploy** with **reload** for `dev-staging` and for `prod-us`, so their Collectors use
   the new ingest password.
4. On the telemetry host, run `sudo systemctl restart rentsync.service`.
5. Check that telemetry from both environments still arrives (quickstart §5).

**OpenObserve metadata database password** (shared). Terraform generates this password; nobody
types it. Every time the telemetry host starts, `rentsync-start` sets the `openobserve`
database user's password to the value in SSM and only then starts OpenObserve, so a restart is
all the database needs:

1. In `rentsync-shared-us`, increase `openobserve_db_password_version` by 1. Apply (confirm).
   A new random password is written to `/rentsync/shared-us/openobserve/db_password`.
2. Restart the telemetry stack, in a session on the telemetry host
   (`aws ssm start-session --target <instance_id>`):

   ```bash
   sudo systemctl restart rentsync.service
   sudo journalctl -u rentsync.service -n 20 --no-pager   # ends with "password matches SSM"
   ```

   OpenObserve restarts with the new password, so it is down for a few seconds. The
   environments' Collectors queue telemetry meanwhile and then send it.
3. Check that `https://telemetry.<domain>/healthz` returns `{"status":"ok"}` and that new
   telemetry arrives (quickstart §5).

Nothing else uses this password, so the environments need no reload. A host replacement or
reboot after step 1 has the same effect as step 2.

## Replaying failed webhooks on a deployed environment

The admin API is the same as in feature 001 (`specs/001-mock-pms/contracts/openapi.yaml`). Read
the admin token into your own shell from SSM. Never paste it into chat or a file:

```bash
source .bootstrap/settings.env
BASE="https://pms-staging.$RENTSYNC_DOMAIN"     # or https://pms.$RENTSYNC_DOMAIN
DEPLOYMENT_ID=dev-staging                        # or prod-us
ADMIN_TOKEN="$(aws ssm get-parameter --region "$RENTSYNC_AWS_REGION" --with-decryption \
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
   workspaces (§Bootstrap step 2). Pick its apply method. Add it
   to `rentsync-shared-us`'s remote state sharing list, and set its variables:
   - `deployment_id = pr-42`;
   - `environment` (`staging` for anything that isn't production);
   - `hostname = pms-pr-42.<domain>`;
   - its own network, the next free range: `vpc_cidr = 10.43.0.0/16`, `subnet_cidr = 10.43.1.0/24`
     and `private_ip = 10.43.1.42` (ADR-0008);
   - `acme_email` and `acme_ca`;
   - `region` and `hcp_organization`, the same as the other environment workspaces;
   - a fresh `admin_token`.
2. **AWS IAM:** add `"<github-subject>:environment:pr-42"` to the `sub` list in the
   `rentsync-github-actions` trust policy
   ([`iam/github-actions-trust.json`](iam/github-actions-trust.json)). Merge that, then rerun
   `bootstrap-iam.sh --apply` in CloudShell, which updates the role's trust policy. Trust uses
   exact names, so a job in an unlisted Environment can't assume the role (security review
   2026-10-21).
3. **GitHub:** create Environment `pr-42` with `SITE_URL = https://pms-pr-42.<domain>`,
   limited to `main`. Add `pr-42` to the `deployment_id` choice list in
   `.github/workflows/deploy.yml`, which is the only code change.
4. **DNS:** add an A record `pms-pr-42` → the workspace's `public_ip` output.
5. Apply, then run **Deploy** for `pr-42` from `main`.

It gets its own VPC peered only with shared, host, volume, role, parameters (`/rentsync/pr-42/…`), database
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
   source .bootstrap/settings.env
   cd infra/terraform/environment
   export TF_CLOUD_ORGANIZATION="$RENTSYNC_HCP_ORG" TF_WORKSPACE=rentsync-prod-us
   terraform init
   terraform state rm 'module.host.aws_ebs_volume.data'
   ```

   Then, in the HCP UI, open **Settings** → **Destruction and Deletion** → **Queue destroy
   plan**, and confirm.
3. **Empty the image registry**, because ECR refuses to delete a repository that holds
   images (`force_delete = false`):

   ```bash
   source .bootstrap/settings.env
   repo=shared-us/mock_pms
   aws ecr list-images --region "$RENTSYNC_AWS_REGION" --repository-name "$repo" --query 'imageIds[*]' --output json > /tmp/ids.json
   aws ecr batch-delete-image --region "$RENTSYNC_AWS_REGION" --repository-name "$repo" --image-ids file:///tmp/ids.json
   ```

4. Do the same for `rentsync-shared-us` (`infra/terraform/shared`), with
   `terraform state rm 'module.telemetry_host.aws_ebs_volume.data'`, then queue its destroy.
   This also deletes the CloudTrail trail and the log bucket, with every CloudTrail and Flow
   Log record in it. Download anything you want to keep first (§Audit logs).
5. Delete the released data volumes, and any snapshots you don't want:

   ```bash
   source .bootstrap/settings.env
   aws ec2 describe-volumes --region "$RENTSYNC_AWS_REGION" --filters Name=tag:Project,Values=rentsync \
     --query 'Volumes[].[VolumeId,Tags[?Key==`DeploymentId`]|[0].Value,State]' --output table
   aws ec2 delete-volume --region "$RENTSYNC_AWS_REGION" --volume-id vol-…
   aws ec2 describe-snapshots --region "$RENTSYNC_AWS_REGION" --owner-ids self --filters Name=tag:Project,Values=rentsync \
     --query 'Snapshots[].[SnapshotId,StartTime]' --output table
   aws ec2 delete-snapshot --region "$RENTSYNC_AWS_REGION" --snapshot-id snap-…
   ```

6. Delete the A records at your DNS provider.
7. If you're leaving for good, or want to rerun the bootstrap from a blank slate, continue with
   §Bootstrap teardown.

Next day: Cost Explorer, grouped by `DeploymentId`, should show no new charges.

## Bootstrap teardown

This reverses §Bootstrap, so you can rerun the bootstrap from a blank slate or leave for good
(constitution: Reversible bootstrap). Each bootstrap script has a `--teardown` mode. It lists
exactly what it will delete, warns that the deletion is permanent, and asks you to type the answer
to a small sum. A wrong answer, no answer, or no interactive terminal deletes nothing. It's three
runs in two places, because AWS is only reachable from CloudShell.

Teardown refuses while infrastructure still exists, so do §Teardown first if anything was ever
applied. Then, in this order:

1. **GitHub**, on your machine:

   ```bash
   bash infra/bootstrap/bootstrap-github.sh --teardown
   ```

   It deletes the repository variables and both Environments, with their variables, branch
   policies and reviewers.
2. **HCP Terraform**, on your machine (PowerShell on Windows):

   ```bash
   ruby infra/bootstrap/bootstrap-hcp.rb --teardown
   ```

   It deletes the three workspaces, the `rentsync-aws` variable set and the `RentSync` project.
   It uses HCP Terraform's safe delete, and refuses if a workspace still manages resources.
3. **AWS**, in CloudShell from the repository directory, after `git pull`:

   ```bash
   bash infra/bootstrap/bootstrap-iam.sh --teardown
   ```

   It deletes the four bootstrap roles and their policies, by exact name; Terraform's own
   `rentsync-*` host roles are not touched. It also deactivates the `DeploymentId` cost
   allocation tag, and deletes the OIDC providers the bootstrap created. It refuses if any
   instance or volume tagged `DeploymentId` still exists.

**What stays, and why:**
- **OIDC providers the bootstrap adopted rather than created**, because something else may use
  them. Created ones carry the tag `rentsync:bootstrap=true`. The teardown prints the delete
  command for each adopted provider. Before running it for the GitHub provider, check that no
  other repository in the AWS account deploys through GitHub OIDC.
- **Secret scanning and push protection**, which protect the repository either way.
- **The HCP Terraform GitHub connection and your `terraform login` token**, which you created
  yourself.
- **`.bootstrap/settings.env`**, which the next bootstrap reads. Delete it yourself if you're
  leaving for good.

To start again, run §Bootstrap from step 0. Enter keeps each saved setting.
