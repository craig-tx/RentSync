# Quickstart: validate the AWS deployment

**Feature**: `002-aws-deployment`

This guide proves the feature end to end. The step-by-step operator procedures, run as plan-by-default bootstrap
scripts, live in `docs/deploy/runbook.md`, written during implementation. This guide lists what
to run and what to expect, and points to the contracts for details.

## Prerequisites

- Feature 001 merged on `main`, with CI green.
- An AWS account and an HCP Terraform organization, both owned by the operator, and a domain
  whose DNS the operator controls. Their values are the deployment settings
  (`.bootstrap/settings.env`, written by `bootstrap-init.sh`); `<domain>` below is that domain,
  and each code block that uses the `$RENTSYNC_…` values starts by loading them with
  `source .bootstrap/settings.env` (from the repository root).
- Locally: `terraform` ≥ 1.11 (the repository uses 1.16.x), the AWS CLI v2 with the Session
  Manager plugin, `curl`, `jq` and `nmap`. AWS CLI access uses the operator's own console
  sign-in (`aws login` or SSO). No access keys.

## 0. Static checks (no cloud needed)

```bash
terraform -chdir=infra/terraform/shared init -backend=false && terraform -chdir=infra/terraform/shared validate
terraform -chdir=infra/terraform/environment init -backend=false && terraform -chdir=infra/terraform/environment validate
terraform fmt -check -recursive infra/terraform
terraform -chdir=infra/terraform/environment test
terraform -chdir=infra/terraform/shared test
shellcheck infra/host/bin/*
docker compose exec mock_pms bundle exec rspec        # includes the /healthz version and setup --deploy specs
```

**Expected**: everything passes. The CI `infra` job runs the same commands.

## 1. Bootstrap (FR-006, under 1 hour)

Follow runbook §Bootstrap:

0. Save the deployment settings with `bootstrap-init.sh`.
1. Create the OIDC providers and the roles from
   [contracts/bootstrap-iam.md](contracts/bootstrap-iam.md).
2. Create the HCP project, the variable set and the three workspaces, with remote state sharing
   from `rentsync-shared-us` to the two environment workspaces.
3. Enter the variables from
   [contracts/workspace-variables.md](contracts/workspace-variables.md). The script generates
   `admin_token` per environment.
4. Create the GitHub variables and the `dev-staging` and `prod-us` Environments (named by DeploymentId).
5. Activate `DeploymentId` as a cost allocation tag in Billing (it becomes selectable about a day after the first apply).

**Expected**: in HCP Terraform, every `admin_token` and `openobserve_root_password` shows as
"Sensitive". No AWS access key exists: IAM → Users shows no access keys created for this
project.

## 2. Provision (US1, SC-001)

Apply `rentsync-shared-us` (confirm), then `rentsync-dev-staging` (auto), then `rentsync-prod-us`
(confirm). Use `acme_ca` = LE staging for the first run. Then add the three A records from the
outputs (data-model §DNS record). Switch `acme_ca` to production and apply.

**Expected**:

- Three instances exist, each with an Elastic IP that matches its output.
- The DNS check in runbook §DNS shows the staging IP for `pms-staging`, and likewise for the other two
  records.
- The HCP run logs mask every sensitive value, and no state version holds a secret:
  `ruby infra/bootstrap/audit-hcp-secrets.rb` prints PASS (it only reads; see its header).

Check the network surface (SC-003, US1 AC2):

```bash
for ip in <staging_ip> <production_ip> <telemetry_ip>; do nmap -Pn -p 1-65535 --open $ip; done
```

**Expected**: exactly `80/tcp` and `443/tcp` open on each address.

Check shell access with no inbound port (US1 AC3):

```bash
aws ssm start-session --target <staging_instance_id>
```

**Expected**: a shell, with port 22 still closed.

Check network isolation (FR-007, ADR-0008). In that staging session:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.40.1.10:5080/healthz   # telemetry, over peering
curl -s -o /dev/null --max-time 5 http://10.42.1.30/ || echo "no route to prod-us"     # production's private IP
```

**Expected**: the first prints `200`; the second prints `no route to prod-us`. Repeat from a
`prod-us` session against `10.41.1.20`.

## 3. First release (US4)

Push or merge a change to `main`. The `CI` workflow goes green, and then `release.yml` builds
and deploys to staging. On the first deploy, `bin/setup --deploy` seeds the database.

```bash
source .bootstrap/settings.env
curl -s "https://pms-staging.$RENTSYNC_DOMAIN/healthz" | jq
curl -sI "http://pms-staging.$RENTSYNC_DOMAIN/" | head -1         # 308 to https
curl -s -o /dev/null -w '%{http_code}\n' "https://pms-staging.$RENTSYNC_DOMAIN/metrics"   # 404
```

**Expected**:

- `status: ok`, and `version` equals the merge commit SHA.
- The certificate is issued by Let's Encrypt (`curl -v` shows the issuer).
- The time from merge to staging healthy is under 15 minutes (SC-005).

Approve the `deploy-prod-us` job in GitHub. **Expected**:

- `https://pms.<domain>/healthz` reports the same SHA within 10 minutes.
- The build job ran once. Nothing was rebuilt.

## 4. Feature 001 checks on each environment (US2, SC-002)

Run these once with `BASE="https://pms-staging.$RENTSYNC_DOMAIN"` and the staging `ADMIN_TOKEN`, then
again for production.

- **Public checks.** Run the 001 quickstart §3, §4, §8 (replay and idempotent scenarios) and
  §9's `/admin` 401 check with `curl`, replacing `localhost:4001` with `$BASE`. Approve OAuth in
  a browser at `$BASE/oauth/authorize?...`. **Expected**: as in 001.
- **On-host checks.** §5 receiver, §6 hammer and the Redis outage, §7 chaos, and §9 log grep
  need the Compose network or `docker compose exec`. Run them in an SSM session on the host:

  ```bash
  aws ssm start-session --target <instance_id>
  sudo -i; cd /opt/rentsync; set -a; . /run/rentsync/env; set +a
  ```

  Then follow 001 §5–§7 and §9 as written, with `docker compose --profile tools ...` from
  `/opt/rentsync`.
  - Register the receiver client with `subscriber_url` set to `http://receiver:9999/webhooks`,
    which is internal to the host.
  - `bin/hammer` and `bin/chaos_check` use `MOCK_PMS_URL=http://mock_pms:4001`.

  **Expected**: as in 001.
- **One public webhook check.** Register a second client whose `subscriber_url` is a public
  HTTPS receiver you control. Run `tenant_move_out`, then verify `PMS-Signature` with the
  client's `signing_secret`. **Expected**: a valid signature (US2 AC3).
- **Isolation (US2 AC5).** Look up a `client_id` created on staging with
  `GET $PROD/admin/clients/<id>`. **Expected**: 404.

After the chaos checks, set every chaos rate back to 0 on both environments.

## 5. Telemetry (US3, SC-008)

Open `https://telemetry.<domain>`. **Expected**: the OpenObserve sign-in page, over HTTPS,
with no data visible before sign-in.

Sign in, then run `tenant_move_out` on staging and on production.

**Expected**, within 60 s:

- logs and metrics with `deployment.environment` = `staging` / `production` and `deployment.id`
  = `dev-staging` / `prod-us`, which can be filtered apart;
- searching one run's `correlation_id` shows its web and worker lines together.

Stop OpenObserve with `docker compose stop openobserve` in a telemetry-host session. Run a
scenario on staging. **Expected**: the API and webhook delivery are unaffected. Start
OpenObserve again. **Expected**: telemetry resumes.

## 6. Rollback and failed release (US4 AC3, AC4, SC-006)

- Run `deploy.yml` with `deployment_id=prod-us`, `rollback=true`, and approve it.
  **Expected**:
  - within 10 minutes, `/healthz.version` is the previous SHA;
  - the clients, grants and events counts are unchanged (`GET /admin/clients`,
    `/admin/events?limit=1`).

  Redeploy the current SHA afterwards.
- Failed release: on a throwaway branch, merge a change that makes `/healthz` return 503 (for
  example a worker that never heartbeats), or deploy a tag of such an image to staging with
  `deploy.yml`. **Expected**:
  - `rentsync-deploy` prints `rolled back to <old>`;
  - the workflow fails;
  - staging still serves the old version.

  Revert the change.

## 7. Host replacement and restart (US5 AC1, AC5, SC-007)

1. Create a client, a grant and a scenario on staging, and note the counts.
2. Run `sudo reboot` in a session. **Expected**: healthy again with no manual step.
3. Force a replacement: run an apply with `-replace=module.host.aws_instance.this` on
   `rentsync-dev-staging`. **Expected**, within 30 minutes:
   - the same IP;
   - no new certificate issuance; Caddy logs show the certificate loaded from storage;
   - the same counts;
   - pending deliveries resume.

## 8. Backup and restore (US5 AC2–AC4)

- After 05:00 UTC, the EC2 console shows a `rentsync`-tagged snapshot per data volume. After 8
  days there are at most 7 per volume.
- Plan a change that would destroy the staging data volume, for example a changed
  `availability_zone`. **Expected**: the plan errors with `prevent_destroy`.
- Restore staging from the latest snapshot through runbook §Backup restore (`terraform state rm`
  of the current volume, then `data_snapshot_id`; research R14).
  **Expected**: staging serves the data as of that snapshot.

## 9. Secrets and cost (SC-004, SC-009, FR-035)

```bash
gitleaks detect --source . --no-banner         # or GitHub secret scanning: zero findings
ruby infra/bootstrap/audit-hcp-secrets.rb    # HCP state and run logs: PASS, exit 0
```

- Rotate staging's `admin_token` through runbook §Rotate. **Expected**: the old token gets 401,
  and the new one works.
- In AWS Budgets, `rentsync-monthly` shows a $60 limit with 80% actual, 100% actual and 100%
  forecast alerts addressed to `budget_email`.
- Cost Explorer after one full month shows less than $60.

## 9a. DeploymentId and side-by-side (FR-038 to FR-042, SC-011)

```bash
source .bootstrap/settings.env
# Every resource in the region, minus those tagged DeploymentId. Expect only AWS defaults
# (the default VPC and its parts), and nothing named rentsync-*.
aws resourcegroupstaggingapi get-resources --region "$RENTSYNC_AWS_REGION" \
  --query 'ResourceTagMappingList[?!(Tags[?Key==`DeploymentId`])].ResourceARN'
aws resourcegroupstaggingapi get-resources --tag-filters Key=DeploymentId,Values=prod-us \
  --query 'length(ResourceTagMappingList)'
curl -s "https://pms.$RENTSYNC_DOMAIN/healthz" | jq -r .deployment_id     # prod-us
```

Side-by-side check, with no apply needed:

1. Create a throwaway workspace `rentsync-pr-42` on `infra/terraform/environment`, with
   `deployment_id=pr-42`, `vpc_cidr=10.43.0.0/16`, `subnet_cidr=10.43.1.0/24`,
   `private_ip=10.43.1.42`, a dummy hostname and token.
2. Run a speculative plan.

**Expected**: every resource is a create, named `rentsync-pr-42-*` under `/rentsync/pr-42/`, and
nothing in `rentsync-shared-us`, `rentsync-dev-staging` or `rentsync-prod-us` would change.
Delete the workspace afterwards.

After a day, Cost Explorer grouped by the `DeploymentId` tag shows separate spend for
`shared-us`, `dev-staging` and `prod-us`.

## 10. Teardown (runbook §Teardown)

1. For each deployment, release its data volume from Terraform with `terraform state rm`, the
   documented override (FR-034). `prevent_destroy` stays in the code.
2. Queue destroys for production, then staging, then shared, emptying ECR before shared.
3. Delete the released volumes, any snapshots you don't need, and the A records.

**Expected**: Cost Explorer shows no further charges after the next day.
