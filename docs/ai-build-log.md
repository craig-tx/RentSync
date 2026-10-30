# AI Build Log

The constitution's Development Workflow section requires an entry for every build session, whether autonomous or interactive.

**Where an entry goes:** each PR writes its entry into its own slot under [Entries by PR](#entries-by-pr), the one numbered with the PR's number. Open the PR first, then:

```bash
ruby bin/build-log fill <pr-number> entry.md   # or pipe the entry on stdin
```

Two open PRs never touch the same lines, so the log never causes a merge conflict. Entries above the slots are the archive, in session order; don't add to it. CI runs `ruby bin/build-log check`, which warns when fewer than 100 free slots are left; then open a PR that runs `ruby bin/build-log top-up`.

## Entry template

```
### YYYY-MM-DD: <title> (<session type: interactive | unattended>)

- **Done:**
- **Blocked:**
- **Decisions:**

**Next task:**
```

---

### 2026-10-20/21 — interactive: feature 001 (mock PMS), `/speckit-implement`

**Done:**
- All 103 tasks in `specs/001-mock-pms/tasks.md`. Each phase was written test-first: the specs were seen failing, then implemented.
- The suite is 156 RSpec examples, all passing, and RuboCop reports no offenses.
- Commits: Phase 1–2 `7978abf`, US1 `4801787`, US2 `bb4a8bc`, US3 `1759caa`, US4 `8326718`, US5 `247edcb`, and the polish commit.

**T101: quickstart run by hand on Windows 11 with Docker Desktop and Git Bash.** Every section passes:
- **§1 Start:** the stack starts and `/healthz` returns 200 with a worker heartbeat.
- **§3 Seed:** seed 42 with anchor 2026-10-20 gave the same digest on two runs; seed 7 gave a different one. All behaviour categories are present, with 4 move-outs.
- **§4 Connect and read:**
  - the approval page renders, approval redirects with a code, and reusing the code gives `invalid_grant`;
  - all 299 of lonestar's payments page through 6 pages, matching the database count;
  - refresh rotates the tokens, reusing the old refresh token is rejected, and revocation gives 401 `token invalid`.
- **§5 Webhooks:** every delivery has a valid signature and arrives about 0.6 s after the change. With `RECEIVER_FAIL_FIRST=3`, attempt 4 succeeds with the same event ID.
- **§6 Rate limits:**
  - 60 requests succeed, then 429 with `Retry-After: 1`;
  - with requests alternating between two instances, the client still gets 60 successes in total, not 120;
  - when Redis stops, `/v1` fails closed with 503, and it recovers without a restart.
- **§7 Chaos:**
  - over 1,211 events and 1,000 API calls, every rate is within 3 points: duplicate 0.103, out-of-order 0.104, delay 0.047, malformed 0.042, server error 0.106;
  - all 126 reordered deliveries were overtaken by a later one;
  - with chaos off, behaviour is exact;
  - `--determinism` produced identical decision sequences.
- **§8 Replay and scenarios:**
  - a single replay carries the original event ID and `replay: true`;
  - a range replay delivered 57 events in `occurred_at` order;
  - the default burst covered 74% of active leases and was delivered in 2 s;
  - a repeated `Idempotency-Key` returns the same `run_id`, and a mismatched body returns 422;
  - admin calls without a token return 401.
- **§9 Observability:**
  - the Collector reads `/var/lib/docker/containers` under Docker Desktop;
  - logs and every metric family reach OpenObserve;
  - filtering by a scenario's correlation ID shows its web and worker lines together;
  - a scan of the container logs found no secrets or personal data;
  - with OpenObserve and the Collector stopped, the mock keeps working, and telemetry resumes after a restart.

**Defects found and fixed during the runs:**
- **Stdout buffering:** Ruby buffered stdout in containers, so worker logs were invisible to `docker logs` and the Collector. Logging now writes unbuffered.
- **Stale models at boot:** a web process started before its migrations had loaded models without the new columns. Web and worker now run pending migrations at boot under a Postgres advisory lock (recorded in plan.md, Principle X row).
- **Redirect status:** Grape answers a POST over HTTP/1.1 with 303. The OAuth redirects now force 302, as the contract says.
- **Receiver config:** the receiver needed `MockPms.boot!` before using the logging mixin. In Compose, `env_file` overrode the shell's `RECEIVER_SECRET`, so the receiver's `environment` now reads it explicitly.
- **OpenObserve password:** OpenObserve v1.0.4 refuses weak root passwords, so `.env.example` now ships a compliant example.
- **Collector names:** switched to the non-deprecated component names `file_log` and `otlp_http`.
- **`chaos_check` overtaken measure:** it compared scheduled times, which a held delivery has later by design. It now compares creation order with arrival order.

**Test corrections:** each fixed the test itself and kept the assertion as strict.
- A secret sentinel (`"tok"`) also matched the key name `access_token`.
- In Ruby 3, a hash passed to a helper that takes keyword arguments was read as keywords.
- Sequel doesn't allow `update` together with `limit`.
- The end-to-end retry test had both deliveries in a batch using up a "fail first 2".
- A forked child closed the parent's database connections. The test now disconnects before forking.

**T102: constitution compliance pass.**
- **I:** no code updates or deletes events, delivery attempts or reversals; triggers enforce this for events and attempts.
- **II:** every row of the plan's idempotency-key table is enforced and tested.
- **III:** all test-first.
- **VI:** OTLP delivery is verified live, `service.version` is on metrics, and the Collector's drop counters are exported.
- **VII:** redaction is verified both in specs and in a live log scan.
- **VIII:** the Gemfile matches the plan's 6 runtime and 3 development gems.
- **X:** no process-local shared state beyond the allowed metrics buffer, the logging mutex and the cached script SHA. The only lock is the justified migration advisory lock.

**Decisions:**
- `month_end_burst` pays next month's rent, adding the period's charge when needed, so SC-008's 70% target holds on seeded data.
- `chaos_check --generate` alternates bursts with NSF waves, because bursts alone run out of lease periods.
- The `Delivery` Sequel model doubles as the namespace for `Delivery::Worker` and the other delivery classes.

**First CI runs on PR #2.** Three issues, all fixed; the fourth run is green for both `test` and `telemetry-smoke`.
- **Executable bits:** `core.filemode` is off on Windows, so the `bin/` scripts were committed as 100644 and CI exited with 126. Docker Desktop hid this locally. Fixed with `git update-index --chmod=+x`; set this for any new script.
- **`bundle exec`:** `ruby/setup-ruby` installs gems into the bundle, so `bin/setup` needs `bundle exec`.
- **Missing database:** on a fresh stack the worker booted and tried to migrate before `bin/setup` had created the database, and exited. Boot now creates the database when it's missing. Reproduced and verified locally with an isolated Compose project (`-p rs-fresh`).

**Blocked:** nothing.

**Next task:** open a pull request for `001-mock-pms`, merge once CI is green, then `/speckit-specify` the Terraform Cloud and AWS deployment as feature 002 (see the project memory).

### 2026-10-21 — interactive (operator remote): feature 002 (AWS deployment), spec through `/speckit-implement` T001–T052

**Done:**
- **Constitution v1.2.0:** a MINOR amendment adds DeploymentId and `deployment.id` to Principle VI. Every deployment-owned name, path, database and AWS tag derives from it, so deployments can run side by side in one account. The Sync Impact Report stays until merge (T090).
- **Spec:** clarified with DeploymentIds `prod-us`, `dev-staging` and `shared-us` (FR-038–FR-042, SC-011). ElastiCache was rejected on cost.
- **Planning:** plan, research (R1–R17), data model, contracts, quickstart and tasks (92 tasks). `/speckit-analyze` findings were all resolved (2 CRITICAL, 3 HIGH, 6 MEDIUM, 5 LOW).
- **Phase 1 (T001–T007):**
  - provider pins: aws 6.69.1, random 3.9.1, with lock files for linux, windows and darwin;
  - an `infra` CI job;
  - `.terraformignore`;
  - runbook and production-differences skeletons.
- **Phase 2, mock PMS (T008–T022), test-first:**
  - `Settings.deployment_id`, validated, fails fast at boot;
  - `deployment.id` on logs and on `target_info`;
  - `/healthz` and `/healthz/live` report `version` and `deployment_id`;
  - `bin/setup --deploy` never reseeds a database that has data;
  - the Collector endpoint comes from configuration, and a `resource/deployment` processor puts the deployment attributes on the Collector's own metrics;
  - local and CI databases now follow the DeploymentId (`mock_pms_local_dev`, `mock_pms_ci_gh`; CI uses DeploymentId `ci-gh`, because `ci` is shorter than the 3-character minimum).

  Verified: 172 examples, 0 failures; RuboCop clean; `bin/telemetry_smoke` live, including the Collector self-metric with `deployment.id=local-dev`.
- **Phase 2 and US1 infrastructure (T023–T049):** the host module, the shared and environment roots, the host scripts and the systemd units. Verified locally:
  - `terraform test`: shared 5/5, environment 9/9, module 2/2, with mock AWS and the real random provider;
  - the static checks (prevent_destroy, root-volume tags, no SecureString `value`, no `key_name`), each shown to catch a planted violation;
  - shellcheck 0.10.0 clean;
  - the loop-device boot test on `amazonlinux:2023`, which formats once and never again.
- **US1 documents (T050–T052):** IAM policy JSON in `docs/deploy/iam/`, and runbook §Bootstrap and §DNS.

**Developer action:** re-copy `.env` from `.env.example`, or add `DEPLOYMENT_ID=local-dev` and `OPENOBSERVE_OTLP_ENDPOINT` and rename the databases to `mock_pms_local_dev`/`_test`. The old `mock_pms` database is simply left unused. This session did that edit on the operator's `.env`; a backup is in the session scratchpad.

**Blocked (operator needed):**
- T053, the bootstrap (AWS OIDC providers and roles, HCP project, variable set, workspaces, remote state sharing, variables, GitHub variables and Environments). Follow runbook §Bootstrap.
- T054, the first applies and DNS. T055 then verifies against live infrastructure.

**Decisions and deviations from tasks.md:**
- The host module takes `files` and `host_env` instead of a pre-rendered `user_data`, because the template needs the data volume's ID. It also adds the base host files itself (boot and render scripts, units, `daemon.json`), so the roots don't duplicate them.
- `daemon.json` is written by cloud-init directly instead of being installed by `rentsync-boot`. A Docker systemd drop-in (`RequiresMountsFor=/srv/data`) stops restart-policy containers from starting before the data volume mounts on reboot. This is an addition to research R6.
- The loop-device test image is 512 MiB (sparse), because XFS refuses filesystems under 300 MB.
- Host-level assertions (IMDSv2, encryption, root tags, fixed IP) live in `modules/host/tests/`, because a root's tests can't see resources inside a module. CI runs the module tests too.
- Tests use the **real** random provider, because mocked providers can't serve ephemeral resources (Terraform 1.16.6). It runs locally and needs no network after init.
- ECR pull permission is optional in the module, so the telemetry host gets none.
- `rentsync-start` exits cleanly when a host has no stack yet. This happens between US1 and US2/US3 applies.
- The release role's ECR resource is `repository/*/mock_pms`, so a future shared deployment needs no IAM change (contract updated).
- Docker Compose is pinned to v5.6.0 (released 2026-10-02) rather than v5.6.1 (released the same day as this session), with sha256 checksums from its release.

**Review fixes before push:**
- CI's DeploymentId `ci` failed the 3-character minimum, so every CI example would have failed at boot. Local runs all used `local-dev`, so nothing caught it. It is now `ci-gh`, verified by running the suite with that value injected.
- `rentsync-render-env` checked required parameters inside `"$(...)"`, which `set -e` ignores. A missing `admin_token` would have rendered `ADMIN_TOKEN=` and exited 0. All required keys are now checked in the main shell first. A new stub-`aws` test (`render_env_test.sh`, also run in CI) proves the failure path.
- The instance now `depends_on` the EIP association, so cloud-init always has internet on first boot.
- CI runs `apt-get update` before installing xfsprogs.

**Test corrections (no assertion weakened):**
- `setup_deploy_spec` used the wrong migration table name. Sequel's is `schema_info`.
- The `ops_spec` `target_info` regex now also requires `deployment_id`, which makes it stricter.

**Mistake caught:** this session overwrote the existing `.gitattributes` (`* text=auto eol=lf`) without reading it first. It was restored before commit. The original already covers LF for all host files.

**Next task:** the operator performs T053 (runbook §Bootstrap), then T054. Meanwhile, the remaining code tasks can proceed without cloud access: US2 T056–T063, US3 T066–T069, US4 T072–T073, US5 T076–T081, Polish T084–T088.

### 2026-10-21 (continued) — interactive (operator remote): feature 002 code tasks past the operator gate

**Done:**
- **PR #3** opened as a draft, so CI runs on the branch. The first CI run passed all three jobs: `test`, `infra` (its first Linux run) and `telemetry-smoke`.
- **US2 (T056–T063):**
  - the environment Compose stack, where each container gets only the variables it needs;
  - `Caddyfile.env`;
  - `rentsync-deploy`, plus `deploy_test.sh` with stub `docker` and `aws`. It covers deploy, no-op, self-rollback, manual rollback, reload with nothing deployed, and bad input;
  - the user-data wiring, plus a test that keeps the gzipped user data under EC2's 16 KB limit (11.6 KB today);
  - the workflows `build-image.yml`, `deploy-to.yml` and `deploy.yml` (actionlint clean);
  - runbook §First deploy and §Replaying webhooks.
- **US3 (T066–T069):**
  - the telemetry Compose stack and Caddyfile. OpenObserve v1.0.4 was verified locally against a Postgres metadata store (107 tables, `/healthz` 200);
  - telemetry-role coverage in `render_env_test.sh`.

  All pinned images publish arm64, so the R4 `t3.small` fallback is not needed.
- **US4 (T072–T073):** `release.yml` (dev-staging, then an approved prod-us with the same SHA), and runbook §Release, §Rollback.
- **US5 (T076–T081):**
  - the DLM daily snapshot policy, test-first;
  - the CI guards removed;
  - runbook §Host replacement, §Backup restore, §Secret rotation, §Adding a side-by-side deployment and §Teardown.
- **Polish (T084–T088):** `production-differences.md`, ADRs 0005–0007, and the README deployment section.

**Decisions and deviations:**
- **Reload action:** `deploy.yml` and `deploy-to.yml` gained a `reload` option, because re-deploying the running SHA is a no-op. A rotated secret would otherwise never reach the containers.
- **Restore and teardown** release the protected data volume with `terraform state rm`, not the `removed` block the tasks describe. Terraform rejects a `removed` block for a resource the module still declares. The restore rehearsal on `dev-staging` (T083) will confirm the procedure.
- **Release guard:** `release.yml` skips when `ECR_REPOSITORY_URL` is unset, so merging before the bootstrap produces no red runs.
- **Least privilege per container:** containers receive only the variables they use, rather than the whole rendered env file. Caddy never sees the admin token.

**Blocked (operator):**
- T053 (bootstrap) and T054 (first applies and DNS);
- T064, T070 and T082 (applies, deploys and approvals);
- T074 (the prod-us reviewer);
- the live verifications T055, T065, T071, T075, T083 and T089;
- T090–T091 (merge-time: remove the Sync Impact Report, mark the PR ready);
- T092 (the 30-day check).

**Next task:** the operator performs runbook §Bootstrap (T053). Everything after it needs live infrastructure.

**Final review fixes (same session):**
- **Certificate switch before the first deploy:** the Deploy workflow's external check verifies the certificate, and a Let's Encrypt staging certificate fails it. T064 and runbook §First deploy now have the switch to the production CA happen before the first deploy. That is also free then, because no host holds data yet.
- **`rentsync.service` retries:** a one-shot with no retry would have left a host stopped after one transient first-boot failure (US5 AC5). It now has `Restart=on-failure`, `RestartSec=30` and `StartLimitIntervalSec=0`. The instance also depends on its IAM policy and the SSM-core attachment.
- **Restore and teardown docs:** research R14, quickstart §8 and §10, and the T079/T081 notes now match the runbook's `terraform state rm` procedure.
- **OpenObserve password validation:** it now requires upper, lower, digit and special characters, matching OpenObserve v1.0.4's own rule, with a test.
- **ECR retention:** raised from 20 to 100 images, so prod-us's image and its rollback target can't expire while many merges wait for approval.
- **Verified:** EC2 never deletes an existing network interface attached at launch (`DeleteOnTermination` can be true only for interfaces created at launch). So host replacement keeps the fixed private IP and the Elastic IP.

**Pre-live review (same session, at the operator's request):**
- **Rendered user data:** rendered through Terraform from the real files, and validated with `cloud-init schema` on cloud-init 22.2.2, the version on Amazon Linux 2023. All 14 files decode with the right paths and permissions.
- **Host rehearsal** (`infra/host/test/rehearse/`, new): the real scripts and Compose stacks ran inside a privileged docker:dind "host", with fake SSM, a local registry and a loop-device volume. **The first full run passed**: first boot, first deploy with seeding, Caddy, a second deploy without a reseed, the no-op, the automatic rollback, telemetry with `deployment.id`, `--rollback`, host replacement, and no secrets in logs. A second run, strengthened with a special-character password and a `/metrics.json` check, was **stopped by Claude Code because the machine ran low on memory**. That is not a test failure. It still needs a rerun, when memory allows.
- **`/code-review high`:** 10 findings, all fixed.
  1. **Secrets mangled:** secrets were written unquoted to the Compose env file. Verified: `Pa$sw0rd! #x` reached the container as `Pa!`. Values are now single-quoted, and a value containing a quote or newline is refused. Terraform also rejects such passwords at plan time.
  2. **Stalled releases:** the workflow-level `release` concurrency group would hold dev-staging behind a pending prod approval. Removed; serialization is now per deployment.
  3. **Approval enforced only by the workflow:** one GitHub role could run commands on production from any Environment. Production hosts are now tagged `rentsync:deployable=protected`, and a new `rentsync-github-actions-prod` role, trusted only for `environment:prod-us`, is the only role IAM lets touch them. The prod-us Environment overrides `AWS_ROLE_ARN`.
  4. **`/metrics.json` was public:** Caddy now answers `/metrics*` with 404.
  5. **Telemetry ingest reachable from the internet:** Caddy now refuses OpenObserve's ingestion paths on the public hostname.
  6. **SSM write failure after a healthy deploy:** `rentsync-deploy` now retries, then exits 3 with instructions. Previously it failed with an AWS CLI code and SSM kept the old tag.
  7. **Boot failures never retried:** `rentsync-boot` is now `rentsync.service`'s `ExecStartPre`, covered by its retries. The separate unit was removed, and cloud-init starts the service with `--no-block`.
  8. **Old `.env` broke the local Collector:** its settings now have defaults, so an old `.env` still works.
  9. **Misplaced specs:** `ops_spec` heartbeat examples moved back under `GET /healthz`.
  10. **Unjustified dependencies:** justifications for the rehearsal images added to plan.md.

**`/security-review` (same session):**
- **Two candidate findings, each checked separately for false positives.**
  - **Rejected (2/10): HCP role escalation.** The HCP Terraform role can attach any policy to a `rentsync-*` role. No untrusted party can trigger a run: HCP doesn't run speculative plans for fork PRs, and only the owner can push. It is a documented demo trade-off and missing hardening, not a vulnerability. Hardening ideas are recorded in production-differences (separate plan and apply roles, permission boundaries).
  - **Confirmed (8/10, MEDIUM): image poisoning past the prod gate.** The release role trusted `environment:*`. GitHub auto-creates unprotected Environments, so any branch job naming a new Environment could assume the role. It could then push an image under an upcoming `main` commit's tag before CI finished. `build-image.yml` skipped the build because the tag existed, ECR tags are immutable, and hosts pulled by tag. The poisoned image would reach dev-staging and then prod-us past the reviewer.
- **Fixed, as the operator accepted:**
  1. **Exact trust only.** No wildcards: `rentsync-github-actions` trusts only `environment:dev-staging`, and the prod role only `environment:prod-us`.
  2. **Builds separated.** The new `rentsync-github-build` role trusts only `ref:refs/heads/main` and is the only role that can push images. The deploy role lost ECR push.
  3. **Deploys pinned by digest.** `build-image.yml` outputs the digest, both deploys pass `<sha>@sha256:<digest>`, `rentsync-deploy` accepts and records that ref, and `/healthz` is checked against the SHA part. `deploy_test.sh` adds a digest-pinned deploy and a malformed digest.
- **Bootstrap now has four roles.** A new GitHub variable `AWS_BUILD_ROLE_ARN` holds the build role. The Environments' "restrict to main" setting is now required. Adding a side-by-side deployment adds one exact subject to the release role's trust. That is a deliberate exception to "no shared change", documented in R17 and the runbook.
- **Strengthened rehearsal rerun: PASSED** at `ea0e377`, run in the foreground with 12 GB free.
  - OpenObserve's password `Re$hearsal #0nly-Pw1` survived end to end: OpenObserve started with it, and the Collector authenticated with it. Telemetry, including the Collector's self-metric, arrived with `deployment.id=pr-42`.
  - `/metrics.json` answers 404 through Caddy.
  - All earlier steps pass again: first boot, the first and second deploys, the no-op, the self-rollback, `--rollback`, host replacement (no reformat, data and certificates kept), and no secrets in logs.
  - Not covered: the rehearsal deploys bare tags. Digest-pinned refs are covered by `deploy_test.sh`, and will be proven live on the first dev-staging deploy.

**Next task:** the operator performs runbook §Bootstrap (T053), now with four IAM roles and `AWS_BUILD_ROLE_ARN`.

### 2026-10-25 — interactive: scripted IAM bootstrap

**Done:**
- **Operator hit "The policy failed legacy parsing"** while pasting `hcp-terraform-policy.json`.
  The JSON was valid, so the cause was a leftover `<account>` placeholder (that file has five).
  The operator had also filled the real account ID into the tracked `iam/*.json` files and the
  runbook's ARN table. **Decision:** keep placeholders in the public repo. The ARNs live in the
  GitHub and HCP variables. The working-tree edits were verified byte-identical to the script's
  render, then reverted. Nothing with the account ID was committed.
- **`infra/bootstrap/bootstrap-iam.sh` (T052a):** runbook steps 1–2 as AWS CLI commands, for
  CloudShell (console session, no access keys). It:
  - reads the account from STS;
  - renders into the gitignored `.bootstrap/iam/` and fails on any leftover `<…>` placeholder;
  - validates every document with Access Analyzer (identity policies, and trust policies as
    `AWS::IAM::AssumeRolePolicyDocument`), and stops on an ERROR or SECURITY_WARNING;
  - prints the plan by default and changes things only with `--apply`;
  - is idempotent: it skips existing providers and policies, refreshes an existing role's
    trust policy, and prints, but never runs, `create-policy-version` for an existing policy
    (the five-version limit);
  - ends by printing the four role ARNs and where each goes.

  `--render-only ACCOUNT` writes paste-ready files for the console path.
- **Test:** `bootstrap_iam_test.sh` uses a stub `aws` and covers the render, a bad account,
  a leftover placeholder, a plan with no mutations, apply on an empty account, apply on a
  half-done account, and an Access Analyzer error that blocks every change. Mutation-checked:
  it fails when plan mode makes a change. Added to CI's shellcheck and as its own step.
- **Runbook §1–2:** CloudShell is now the recommended path; the console steps are the fallback.
- **Suite:** rspec 172/0, rubocop clean, terraform fmt/validate/test pass,
  check_prevent_destroy ok, shellcheck clean.
  - `render_env_test`, `deploy_test` and `bootstrap_iam_test` pass on Linux.
  - `deploy_test` needs `jq`, which CI's runner has.
  - The host tests can't run under Windows Git Bash (file modes).

**Not verified:** the live CloudShell run. It will confirm two things the stub can't:
- `create-open-id-connect-provider` without `--thumbprint-list` (optional in current CLIs; the
  local 2.9.17 still requires it);
- the Access Analyzer flags.

**Next task:** the operator runs `bootstrap-iam.sh` in CloudShell (plan, then `--apply`), and
continues runbook §Bootstrap from step 3 (T053).

**CloudShell plan run (same session):**
- **Plan:** the operator had already created both providers and all four policies and roles in
  the console. The plan was only the four trust refreshes and four idempotent attachments.
- **Bug found before apply: immutable OIDC subjects.**
  - The repository was created 2026-10-20, after GitHub's 2026-07-15 cutoff, so its tokens carry
    `sub = repo:craig-tx@16706018/RentSync@1427164274:…`. Confirmed with
    `gh api repos/craig-tx/RentSync/actions/oidc/customization/sub`.
  - The three GitHub trusts expected `repo:craig-tx/RentSync:…`, so every Actions job would have
    been refused by STS.
  - Fixed in the trust files, contracts/bootstrap-iam.md (with a note on the format) and the
    runbook's side-by-side example. `bootstrap_iam_test.sh` now fails on the old form
    (mutation-checked).
- **Access Analyzer findings, accepted:**
  - `CONFIRM_AUDIENCE_CLAIM_TYPE` (SUGGESTION) on every trust is informational. `aud` already
    uses a plain single-valued `StringEquals`.
  - `SPECIFIC_GITHUB_REPO_AND_BRANCH_RECOMMENDED` (WARNING) on the two Environment trusts: the
    subjects have no wildcard, but an Environment subject carries no branch. The branch rule is
    the Environments' "restrict to main" setting, which the runbook requires. GitHub's AWS OIDC
    guide documents only the `aud` and `sub` keys, so no untested `:ref` condition was added.

**IAM bootstrap applied, GitHub configured, HCP bootstrap scripted (same session):**
- **IAM:** the operator deleted the console-made policies and roles, and ran `bootstrap-iam.sh --apply` in
  CloudShell: 12 changes (4 policies, 4 roles, 4 attachments), with the existing OIDC providers
  reused. This is the first live run of the script.
- **GitHub (runbook step 7), with `gh` at the operator's request:**
  - repository variables `AWS_BUILD_ROLE_ARN`, `AWS_ROLE_ARN` and `AWS_REGION`;
  - Environments `dev-staging` and `prod-us`, with custom deployment branches limited to `main`;
  - `SITE_URL` for each, and the prod-us `AWS_ROLE_ARN` override. All verified.
  - Left for the operator: secret scanning and push protection, both found **disabled** (step
    7.3, SC-004).
  - Left for later: `ECR_REPOSITORY_URL` (after the shared apply) and the prod-us reviewer (T074).
- **`infra/bootstrap/bootstrap-hcp.rb` (T052b):** runbook steps 4–6 through the HCP Terraform
  API, in Ruby with the standard library only (no `jq` on Windows, and no new dependency).
  - **Secrets:** each `admin_token` is generated in the script, a different one per environment,
    and never printed. The OpenObserve password is asked for twice without echo, and checked
    against Terraform's rule before any change.
  - **Reruns:** drifted workspace settings are restored; variables are create-only, and a
    difference is reported but never changed.
  - **Options:** `--branch` (default `main`) and `--health-assessments` (opt-in, Standard tier).
  - **GitHub connection:** never guessed. It must be exactly one OAuth token or one GitHub App
    installation for `craig-tx`, or a flag; otherwise the script fails with the HCP steps.
  - **Test:** `bootstrap_hcp_test.rb`, against a fake API, 8 tests. Mutation-checked: plan-mode
    writes, unreported differences, a late password prompt and prod auto-apply are each caught.
    Passes on Ruby 3.3, CI's version. CI's `infra` job installs Ruby for it.
- **Open question for the operator: which branch the workspaces track.**
  - `main` has no Terraform yet (only `infra/otel`), so a VCS workspace on `main` has nothing to
    plan until 002 merges.
  - `rentsync-github-build` trusts only `refs/heads/main`, so the first image build also needs
    002 on `main`.
  - That conflicts with T090–T091 coming after the live checks. Nothing in the spec covered a
    pre-merge apply.

**Next task:** the operator decides the branch question. Then they run `terraform login` and
`bootstrap-hcp.rb` (plan, then `--apply`) from PowerShell, and continue to runbook step 8 and
T054.

### 2026-10-25 (later): account naming, shellcheck, and the merge

- **Flag rename:** `bootstrap-hcp.rb --account` became `--aws-account`. The operator had read it
  as an HCP account; it is the AWS account ID used to build the `rentsync-hcp-terraform` role ARN.
- **Constitution v1.3.0 (MINOR):** a new rule in Development Workflow & Quality Gates, "Explicit
  system names". Every account reference (docs, flags, placeholders, comments, names, messages,
  specs) must name its system. Only names the project does not control, such as STS's `Account`
  field, are exempt. Feature 002 was brought into line: the IAM placeholder `<account>` became
  `<aws-account-id>`, `bootstrap-iam.sh --render-only AWS_ACCOUNT_ID`, and AWS, HCP Terraform,
  OpenObserve or Let's Encrypt is now named in the runbook, ADR 0005, spec, plan, research, data
  model and tasks. Past build-log entries are left as written.
- **Shellcheck SC2337:** shellcheck 0.11 flags `grep -q` at the end of a pipeline under
  `pipefail`. CI's older shellcheck did not. The risk is real: an early grep exit can SIGPIPE
  the writer and flip the result. `render_env_test.sh`'s "secret never printed" check could
  pass falsely, and `bootstrap-iam.sh`'s provider checks could report "missing". All 15 sites
  now use here-strings. Shellcheck 0.11 is clean, and the render-env, deploy, bootstrap-IAM and
  prevent_destroy checks pass on Ubuntu 24.04.
- **Decision: merge before the live checks.** The operator chose to merge 002 now, so the HCP
  Terraform workspaces can track `main` and image builds (trusted for `main` only) can run.
  T090 removed the Sync Impact Report. T091 is ticked with a note. The operator and live-check
  tasks run against `main` afterwards, and T091a records their results. The release workflow
  stays skipped until `ECR_REPOSITORY_URL` is set, so the merge deploys nothing.

**Next task:** T053. The operator runs `bootstrap-hcp.rb` (plan, then `--apply`) on `main`, then
runbook step 8 and T054.

### 2026-10-25 (later still): GitHub bootstrap script, script-only runbook

- **`infra/bootstrap/bootstrap-github.sh` (T052c):** the GitHub part of the bootstrap, through
  `gh api`. It sets:
  - the repository variables;
  - both Environments, restricted to `main`;
  - each Environment's `SITE_URL`, and the prod-us `AWS_ROLE_ARN` override;
  - secret scanning and push protection.

  It also has `--ecr-repository-url` (after T054) and `--prod-reviewer` (T074). It plans by
  default and builds the role ARNs from `--aws-account`.
  - **Reruns:** a differing value is set again, and an extra deployment branch is removed.
  - **Reviewers:** an existing reviewer is carried into every Environment update, so a rerun
    never removes one.
  - **Test:** `bootstrap_github_test.sh`. A stub `gh` serves JSON files through real `jq`, so the
    script's `--jq` expressions are exercised. Mutation-checked: plan-mode writes, dropped
    reviewers, and an unremoved extra branch are each caught.
  - **Live check:** a read-only plan against the real repository listed exactly the six
    variables and nothing else. The operator had asked for those six (set by hand earlier with
    `gh`) to be deleted so the script could set them; they were deleted with `gh variable delete`.
- **Script-only runbook (T052d):** at the operator's request, §Bootstrap no longer has console
  click paths. It has five steps: `bootstrap-iam.sh` (CloudShell), the AMI lookup (AWS CLI),
  `bootstrap-hcp.rb` (PowerShell), `bootstrap-github.sh` (Git Bash), and the cost allocation tag
  (`aws ce update-cost-allocation-tags-status`, about a day after the first apply). Known
  failures are in "If a step fails". The workspace-variable tables now live only in
  contracts/workspace-variables.md.
  - `bootstrap-iam.sh --render-only` existed only for the console path and was removed. Its tests
    now run through plan mode, with the AWS account ID coming from a stubbed STS.
  - spec.md (Bootstrap), contracts/bootstrap-iam.md and quickstart §1 no longer describe a
    click-through console runbook. T054 and T074 now point at the GitHub script.

**Next task:** T053. The operator runs, from `main`:
- `bootstrap-hcp.rb` (plan, then `--apply`);
- `bootstrap-github.sh --aws-account … --apply`;

then T054.

### 2026-10-25 (last): operator-neutral deployment (T052e)

- **Operator's decisions:**
  - make both the runbook and the code generic;
  - include the AWS region;
  - ship placeholders only;
  - add an interactive first script that saves the settings to an uncommitted file the other
    scripts read.

  Spec Session 2026-10-25 records this. Input (4) now describes the reference deployment.
- **`bootstrap-init.sh` (step 0):** asks for each setting and writes `.bootstrap/settings.env`
  as `RENTSYNC_KEY='value'` lines.
  - **Settings:** AWS account, region and zone; HCP Terraform organization; GitHub repository;
    domain; the three emails; and the AMI, which can stay blank.
  - **Validation:** every answer is checked by regex and asked again if wrong.
  - **OIDC subject:** reads the repository's subject prefix from
    `actions/oidc/customization/sub`, rather than assuming a format, and refuses custom
    templates.
  - **CloudShell:** prints a paste block that clones the repository and writes only the four
    settings step 1 needs.
  - **Loading:** `settings.sh` (bash) and `HcpBootstrap.load_settings` (Ruby) read the file as
    data; neither executes it.
- **Scripts:**
  - **IAM:** fills `<aws-region>`, `<hcp-organization>` and `<github-subject>` too, and stops if
    CloudShell is signed in to an AWS account other than the one the settings name.
  - **HCP:** takes the organization, repository, domain, region and zone from settings. It adds
    `TF_CLOUD_ORGANIZATION` to the variable set, `region`, `availability_zone` and
    `telemetry_hostname` to shared-us, and `region` and `hcp_organization` to the environments.
  - **GitHub:** takes the repository, region, domain and AWS account from settings.
  - **Flags:** existing flags still override the settings.
- **Terraform:**
  - the `cloud` blocks no longer name an organization (`TF_CLOUD_ORGANIZATION`);
  - the remote state uses `var.hcp_organization`;
  - `region`, `availability_zone` and `telemetry_hostname` lose their defaults;
  - the tests pass them explicitly.
- **Docs:**
  - the runbook, contracts and quickstart use `<domain>` and `$RENTSYNC_…`;
  - the DNS section is provider-neutral, and the recorded-IP table is gone (the outputs are the
    record);
  - the Git Bash note covers both PowerShell and Command Prompt;
  - the README keeps the reference URLs, labeled as such.

  plan.md, research.md, data-model.md and completed task text keep the reference values as
  design history.
- **Reference deployment unchanged (merge gate):**
  - **IAM:** the new templates, rendered with the reference values, are byte-identical to the
    old render.
  - **HCP:** a live read-only plan with those values listed exactly 8 additions, each equal to
    the old default.
  - **GitHub:** a live read-only plan showed no changes.
- **Tests:**
  - new `bootstrap_init_test.sh`, mutation-checked: a dropped validation and leaked CloudShell
    keys are each caught;
  - the IAM, GitHub and HCP tests now use a non-reference deployment (eu-west-2, example
    org/repo/domain, classic subject format);
  - HCP gained a settings-loader test and an upgrade test (only the new variables are added);
  - HCP: 10 runs, 131 assertions; all shell tests pass; shellcheck 0.11 is clean; Terraform
    7, 12 and 2 tests pass.

**Next task:** before merging this PR, the operator runs `bootstrap-init.sh`, then
`bootstrap-hcp.rb --apply`, which adds the 8 variables. The PR's HCP Terraform speculative plans
must then pass with no changes, which also proves that a `cloud` block without `organization`
works. Then merge, and continue T053/T054.

### 2026-10-25 (closing): reversible bootstrap (constitution v1.4.0, T052f)

- **Constitution v1.4.0 (MINOR):** new "Reversible bootstrap" rule in Development Workflow &
  Quality Gates, at the operator's request so they can rerun the bootstrap from a blank slate.
  - Everything the bootstrap provisions must be removable by a teardown, and every step ships
    with its own.
  - The teardown lists what it will delete, warns that the deletion is permanent, and deletes
    only after a correct answer to a sum typed at an interactive terminal.
  - It refuses while infrastructure depends on its targets. It removes only what the bootstrap
    created, and leaves security protections on.

  The Sync Impact Report is in the file for review and must be removed before merge.
- **`--teardown` on all three scripts:**
  - **Shared confirmation:** `confirm_teardown` (bash, in `settings.sh`) and
    `HcpBootstrap.confirm_teardown` (Ruby). `RENTSYNC_TEARDOWN_NUMBERS` fixes the sum for tests;
    the terminal check still applies.
  - **IAM:**
    - targets the four roles and policies by exact name. Terraform's own `rentsync-*` roles share
      the prefix, so there is no glob;
    - order: detach, delete inline policies, delete the role; then old policy versions, then the
      policy;
    - refuses if a policy is attached elsewhere, or if tagged instances or volumes exist (EC2 and
      EBS, not the tagging API, which lags);
    - deletes only providers tagged `rentsync:bootstrap=true`, which the bootstrap now adds on
      create. The operator's current providers were adopted, so teardown keeps them and prints
      the delete command;
    - deactivates the cost allocation tag.
  - **HCP Terraform:**
    - refuses on any resource count or lock;
    - deletes workspaces through safe-delete, then the variable set, then the project, unless the
      project holds other workspaces.
  - **GitHub:** deletes the variables and Environments, and keeps secret scanning.
- **Tests:**
  - the shell tests drive the confirmation through `script -qec`, so the terminal path really
    runs;
  - the no-terminal case pipes the *correct* answer, so only the terminal check can refuse it;
  - mutation-checked: dropping the terminal check fails both shell tests, and skipping the
    confirmation fails the HCP Terraform test. The first version of the GitHub test missed the
    terminal mutation, which is why the no-terminal case was strengthened;
  - HCP Terraform: 15 runs, 170 assertions.
- **Live, read-only:** the GitHub and HCP Terraform teardowns, run without a terminal, listed
  exactly the live variables, Environments, workspaces, variable set and project, then refused.
- **Also:** the CloudShell settings block now works on an existing clone; it had failed on the
  operator's CloudShell. HCP Terraform ran no speculative plans for PR #5 (no runs on any
  workspace), so its green check proved nothing. The `cloud` block without `organization` will be
  proven by a CLI-driven speculative plan after the re-bootstrap.

**Next task:** the operator reviews PR #5. Before merge: remove the v1.4.0 Sync Impact Report.
Then, for the blank slate:
1. Teardown in order: GitHub, HCP Terraform, then IAM in CloudShell.
2. Optionally delete the two adopted OIDC providers.
3. Rerun §Bootstrap from step 0.
4. Run the CLI speculative plan check, then continue with T054.

### 2026-10-25: macOS-friendly runbook (T052g)

- **Why:** the operator noted that the runbook read as Windows-only, while the evaluators use
  Macs.
- **Two blockers on a stock Mac:**
  - bash 3.2, where `set -u` treats an empty array as unbound, so the teardowns would crash;
  - Ruby 2.6, which can't parse `bootstrap-hcp.rb`'s endless methods.
- **Decision (operator):** require bash 4.4+ and Ruby 3+, both from Homebrew, rather than support
  the old versions.
- **Runbook:**
  - steps and commands are OS-neutral;
  - a macOS setup block (`brew install bash ruby gh hashicorp/tap/terraform`, plus a PATH line
    for Homebrew's keg-only Ruby);
  - one Windows note collects the Git Bash/WSL paths and the PowerShell requirement for the
    hidden password prompt.
- **Scripts:**
  - `settings.sh` refuses bash older than 4.4 with the fix. The check is written to stay valid
    in bash 3.2, so it runs before anything else can fail;
  - script messages no longer assume Windows.
- **CI:** a new step runs the three bash scripts under `bash:3.2` and `bash:4.3`, which must
  refuse, and `bash:4.4`, which must pass the check. Verified locally with the same images.
- **Not tested:** nothing ran on a real Mac. The containers cover the bash risk; the Ruby
  requirement is documented, not checked by the script.

**Next task:** unchanged. The operator runs the blank-slate teardown and re-bootstrap from
`main`, then T054.

### 2026-10-25: one VPC per deployment (ADR-0008, T052h)

- **Operator's decision:** separate VPCs for staging and production, to avoid review questions
  about environments sharing a network.
  - Three VPCs, one per deployment, chosen over putting shared telemetry inside staging's VPC.
    With shared in staging, production's telemetry would depend on staging's network, and it
    breaks deployment ownership.
  - The operator asked that the docs say plainly: this demo uses VPC isolation; true production
    would use the gold standard, the Multi-Account Strategy via AWS Organizations. That phrase
    is in the spec clarification, ADR-0008, production-differences and the README.
- **Terraform:**
  - **`modules/network`:** each deployment gets a VPC, subnet, gateway and route table, with
    standalone routes only.
  - **Environment root:**
    - creates its VPC in the shared zone, and peers it with the shared VPC (auto-accepted,
      same account);
    - adds a route to the shared range, plus the return route in the shared route table;
    - adds the OTLP rule on the telemetry security group: 5080 from its subnet only.
  - **The `otlp-client` group is gone,** because a security group can't be attached across VPCs.
  - **Ranges:** shared `10.40.0.0/16`, staging `10.41.0.0/16` (host `10.41.1.20`), prod
    `10.42.0.0/16` (host `10.42.1.30`).
  - **No `moved` blocks:** no workspace has state.
- **Advisor-flagged trap:** inline `route {}` blocks are authoritative. A shared apply would
  silently delete each environment's return route, and with it telemetry.
  - The module uses standalone `aws_route` resources.
  - `check_prevent_destroy.sh` now fails on any inline route, ingress or egress block. It was
    mutation-checked by injecting both kinds.
- **Tests:**
  - new module tests (4);
  - a new environment network test: peering to shared only; both routes; OTLP from its own
    subnet only; shared zone; staging and production each route privately only to
    `10.40.0.0/16`;
  - mutation-checked: opening OTLP to `0.0.0.0/0` fails the environment network test;
  - Terraform: shared 7, environment 15, host 2, network 4;
  - `bootstrap-hcp.rb` sets the new variables; its tests pass, 15 runs.
- **Docs:**
  - spec: Session 2026-10-25 supersedes input (1), and FR-007 and FR-011 are rewritten;
  - ADR-0008 is new, and ADR-0005's "one VPC" is marked superseded;
  - contracts, data model, research (amendment notes), plan (amendment note), runbook
    side-by-side, and the README;
  - quickstart §2 gains a live isolation check: staging reaches telemetry, but not production.
- **Cost:** unchanged. VPCs, gateways and same-zone peering traffic are free.

**Next task:** merge, then the operator's re-bootstrap. Step 3 hasn't run, so the new variables
land on the first apply. Then the CLI speculative plan check, then T054.

### 2026-10-25: hardening from review (T052i)

- **Why:** the operator asked which AWS and Ruby best practices the demo was missing. They chose:
  - the five cheap, high-signal fixes;
  - a monthly AMI-patching procedure;
  - production-differences entries, including a CSPM such as Orca;
  - then Flow Logs and CloudTrail as real additions.
- **Image:** the Dockerfile had `bundle config set without ""`, so production shipped test and
  lint gems, a compiler, and ran as root. It is now multi-stage:
  - `production`, the default and what releases build: runtime gems only, no compiler, UID
    10001. It loads the app; 316 MB against 852 MB for dev;
  - `dev`, for local Compose and in-container RSpec.

  `rentsync-boot` chowns `/srv/data/receiver` to UID 10001, and the boot-volume test asserts it.
- **Supply chain:**
  - Dependabot weekly for bundler, docker, github-actions and terraform;
  - all seven third-party Actions pinned to commit SHAs with exact-version comments;
  - CodeQL for Ruby.
- **CI scanning:**
  - `bundle-audit` 0.9.2 (no vulnerabilities today);
  - Trivy 0.57.1 config scan. Its four findings are deliberate and justified in
    `.trivyignore`: unrestricted egress, and AWS-managed rather than customer-managed KMS
    encryption.
- **Audit logging (shared deployment):**
  - one bucket, `rentsync-shared-us-logs-<AWS account ID>`: public access blocked,
    bucket-owner-enforced ownership, SSE-S3, 90-day expiry, TLS-only policy, and service
    writes limited to this account's trail and flow logs;
  - a multi-region CloudTrail with log file validation;
  - an `aws_flow_log` in the network module, so every deployment's VPC is covered, under its
    own prefix;
  - `force_destroy` on the bucket: CloudTrail and Flow Logs write until destroyed, so emptying
    it by hand would race them. The runbook warns to copy logs out first;
  - the HCP Terraform policy gains S3 (`rentsync-*`), CloudTrail (`trail/rentsync-*`) and
    log-delivery permissions, which the operator's re-bootstrap picks up.
- **Tests:** a new shared audit test; a network Flow Logs test; Terraform shared 9, environment
  15, network 5, host 2; every shell test; shellcheck; HCP 15.
- **Not run here:** the host rehearsal with the new production image. CI's telemetry smoke test
  covers the dev image in Compose.

**Next task:** merge PR #7, retarget and merge this PR, then the operator's re-bootstrap from
step 1 (the IAM policy changed) and T054.

### 2026-10-25: first dependency review (constitution v1.5.0, "Dependency maintenance")

Dependabot's first run opened seven PRs. Each was reviewed against its release notes and
against the inputs this repository actually passes.

| PR | Update | Decision | Why |
|---|---|---|---|
| #9 | parser 3.3.13.0, rack-test 2.3.0, rubocop 1.92.1 (dev/test gems) | merge | Patch and minor updates; CI green. Merging is left to the operator, because the agent's merge of a bot PR was blocked. |
| #11 | AWS provider 6.69.1 → 6.70.0 (shared, environment) | merge | Minor version; all Terraform tests pass. |
| #12 | `codeql-action/init` 3 → 4 | superseded | `init` and `analyze` must match. Only `init` moved, so `analyze` failed. Replaced by a PR that bumps both to v4.39.1, and Dependabot now groups them. |
| #13 | `setup-buildx-action` 3 → 4 | merge | v4 moves to Node 24 (GitHub-hosted runners qualify) and removes deprecated inputs. We pass none. It isn't exercised by PR CI; the first release proves it. |
| #14 | `setup-terraform` 3 → 4 | merge | Node 24 only. Our `terraform_version` and `terraform_wrapper` inputs still work; CI green. |
| #15 | `configure-aws-credentials` 4 → 6 | merge | v5 changed boolean input parsing, and v6 moves to Node 24. We pass only `role-to-assume` and `aws-region`. It isn't exercised by PR CI; the first release and deploy prove it. |
| #16 | `actions/checkout` 4 → 7 | merge | Node 24; credentials persisted to a separate file (v6); v7 refuses fork-PR checkouts under `pull_request_target` and `workflow_run`. Our `workflow_run` (release) only builds pushes to `main`, never fork PRs. CI green. |

No major-version port is outstanding beyond these. The next quarterly review covers Ruby, Postgres
16, Redis 7 and the Terraform CLI.

### 2026-10-26: cross-platform development (constitution v1.7.0)

- **Done:** constitution v1.7.0 adds "Cross-platform development": a developer can build, test,
  run and operate the project from Windows or macOS (PR #20). PR #21 replaced a GNU-only
  `sed -i` in the IAM bootstrap test. This change adds `infra/test/run.sh`, which runs the host
  and bootstrap shell tests in a pinned Debian container (`infra/test/Dockerfile`, with `jq`).
  CI now calls the same runner, so it can't break unnoticed. `render_env_test.sh`'s mode check
  also accepts BSD `stat`. The README has a "Running the tests" section for both platforms.
- **Found:** on Windows (Git Bash), four of the five shell tests failed natively. Git Bash has
  no `script(1)` (the teardown tests fake a terminal with it), no `flock` (deploy test), no
  `jq` (the gh stub), and NTFS ignores `chmod 600` (render-env test). The macOS forms of
  `script` and `stat` differ from Linux.
- **Decision:** the documented way to run the shell tests is the container, on both Windows and
  macOS, rather than native per-platform branches. The scripts under test run on Linux (EC2
  hosts, CloudShell), and a native macOS branch could not be verified without a macOS CI job.
  The constitution rule allows "run inside Docker". `boot_volume_test.sh` (root, loop devices)
  and the bash 3.2/4.3 refusal step stay CI-only; the HCP Ruby test and `terraform test` run
  natively (both verified on Windows).
- **Tests:** `infra/test/run.sh` 5/5 in Docker on Windows, read-only mount; a deliberately
  broken assertion was reported as FAIL with exit 1; HCP Ruby test 15 runs, 0 failures;
  `terraform test` on modules/network 5 passed; shellcheck clean.
- **Not verified:** the runner on a Mac (no Mac here). Docker Desktop behaves the same there,
  and the script has no Windows-only path except the `cygpath` branch.

**Next task:** the operator's blank-slate re-bootstrap, then T054.

### 2026-10-26: AMI lookup folded into bootstrap step 1

- **Done:** `bootstrap-iam.sh` (CloudShell) ends its plan and apply by reading AWS's public
  parameter for the latest Amazon Linux 2023 arm64 AMI in the settings' region, and prints
  `bootstrap-init.sh --ami <id>`. The new `--ami` flag changes only the AMI ID, with no prompts
  and no GitHub call. The separate lookup step is gone, so the runbook's bootstrap steps are now
  0–4 (HCP is 2, GitHub 3, cost tag 4), with references renumbered in scripts, tests and specs.
  The monthly patching procedure uses `--ami` too.
- **Decisions:** `bootstrap-init.sh` cannot do the lookup itself, because the operator's machine
  has no AWS credentials by design (no access keys; CloudShell is the AWS session). The ID needs
  no human confirmation: its source is AWS's own parameter, and the `rentsync-shared-us` plan
  shows it before the confirmed first apply. A failed or malformed lookup warns without failing
  the IAM run, because the IAM changes are already done by then.
- **Tests:** init test (new case 5: `--ami` alone, refusals, settings untouched); IAM test
  (lookup in the right region and parameter, printed command, failure and malformed-value
  warnings), run in the infra test container; each new assertion was shown to fail against a
  broken script. HCP test 15/170; shellcheck clean.
- **Historical task text** (T052a, T052b) keeps the step numbers it was written with.

**Next task:** the operator's blank-slate re-bootstrap with the new step 1, then T054.

### 2026-10-26: CloudShell gets every setting; where hand-typed commands run

- **Found (operator):** the certificate check failed in CloudShell, whose settings copy held
  only the four values step 1 needs (no domain), and `source` failed in Windows Command Prompt.
- **Done:** step 0's CloudShell block now writes every setting (all are non-secret), so each
  runbook block works in either place. The runbook intro says where commands run: `aws` in
  CloudShell, everything else in Git Bash or macOS Terminal (not PowerShell or Command Prompt).
  The certificate check is now a block covering all three hosts.
- **Test change (requirement changed, not weakened):** the init test asserted the CloudShell
  block carried exactly four settings; it now asserts the block is identical to the local
  settings file. A mutation back to four settings fails it.
- **Checked live:** all three hosts already serve trusted Let's Encrypt production certificates.

**Next task:** merge #25, #26 and this; then §First deploy.
### 2026-10-26: host memory measured; swap file on every host

- **Done:** measured the environment stack on the local Compose stack with the production
  `mock_pms` image, idle and under load (1,248 events, 599 webhook deliveries, 6,400 HTTP
  requests from 8 clients, a first-deploy setup). Containers peak at ~500 MiB, so a host at
  ~750–800 MiB with the OS; OpenObserve alone peaked at 949 MiB (research R4 table). Every
  host now gets a 1 GiB swap file at first boot (`rentsync-swap`, `swap_mib`, swappiness 10).
  Runbook §Changing a host's instance type covers trying `t4g.micro` on staging.
- **Decisions:** `t4g.small` stays the default; `t4g.nano` is ruled out; the telemetry host
  stays `t4g.small`. The swap change alters user data, so the next apply of each workspace
  **replaces its host** (data, IP and certificates kept). Applied now, while no host holds
  data, that costs nothing.
- **Found:** the local `rentsync/mock_pms:dev` image predated the gem updates from PR #9, so
  recreated containers failed with Bundler::GemNotFound. Rebuilt it. `mock_pms_b` still runs
  the old image. The local database had no webhook client, so the first load run exercised no
  deliveries; a `memory-load` client was registered for the second.
- **Tests:** host module Terraform tests (5, including swap on, off and too large); every root's
  tests; `swap_test.sh` in a privileged Linux container (it needs a real filesystem, not
  overlayfs); a mutation of each new check failed as expected. Not measured: the OS overhead,
  and Graviton rather than x86_64.

**Next task:** first applies (§First apply), then a deploy and `free -m` on `dev-staging`.

### 2026-10-26: first deploy failed on the SSM command comment

- **Found (operator, first Deploy run):** `aws ssm send-command` rejected the comment
  `rentsync-deploy <sha>@sha256:<digest>` (128 characters; SSM allows 100). The pinned-digest
  argument (R9) made it too long; the command itself was fine. No test exercised the workflow
  against the real API, so this first showed on a live run.
- **Done:** the comment is now `rentsync-deploy <deployment_id> <sha>`, at most 73 characters.
  The command still pins `<sha>@sha256:<digest>`.

**Next task:** rerun Deploy for `dev-staging` once merged.

### 2026-10-26: HCP Terraform never queued a run from GitHub

- **Found:** every run in the three workspaces was started in the UI. HCP Terraform received
  each push and pull request (it posted a "Success" status on every commit) but matched no
  workspace. The workspaces' trigger pattern was `infra/**`; every documented pattern is anchored
  with a leading slash (`/module/**/*`). This is the cause of the earlier "vacuous green"
  speculative plans and of merges not starting runs.
- **Done:** `bootstrap-hcp.rb` sets `/infra/**`. Rerunning step 2 with `--apply` updates existing
  workspaces (it restores drifted settings). Test: the pattern, and its restoration on a
  workspace that still has the old one; the old pattern fails the test.
- **Docs:** `jq` was used by the runbook but never listed. It is now in the tools for macOS
  (brew) and Windows (a winget line covering every tool; package IDs verified).
- **Not yet verified:** that a push touching `infra/` now queues runs. The first merge after the
  operator reruns step 2 shows it; until then this is the documented format, not observed.

**Next task:** operator reruns bootstrap step 2 with `--apply`; watch the next `infra/` merge.

### 2026-10-26: Collector GOMEMLIMIT (also the first trigger-pattern test)

- **Done:** the environment hosts' Collector gets `GOMEMLIMIT=204MiB`, ~80% of its
  `memory_limiter` limit, as the Collector docs advise; `collector.yaml` notes the pairing.
  Research R4 corrected: the test receiver runs only under the `tools` profile, so an
  environment host peaks at ~700–750 MiB, not 750–800.
- **Also the test of the anchored trigger pattern:** this is the first `infra/` merge after the
  operator's step 2 rerun (workspaces updated 21:32:18 UTC; the last earlier merge's push landed
  at the same moment). Expected: runs queue in all three workspaces; `rentsync-dev-staging`
  applies on its own; `rentsync-shared-us` and `rentsync-prod-us` wait for confirmation. Each
  replaces its host, which also applies PR #26's swap, never applied so far (its merge at
  21:06 UTC came after the last manual runs).
- **Tests:** Collector `validate` with the new environment; the host Compose file renders it;
  Terraform tests (environment 15, shared 9, host module 5); infra shell tests 5/5.

**Next task:** watch the runs after merge; check dev-staging's `/healthz` still reports the
deployed SHA after its host is replaced.

### 2026-10-27: why HCP Terraform never ran from GitHub (found by experiment)

- **Experiments** (operator changed `rentsync-dev-staging`'s VCS settings in the UI; empty or
  scratch commits on draft PR #32; the PR's "Terraform Cloud" status showed whether a
  speculative plan started: "0 of 1 complete" vs a bare "Success"):

  | dev-staging setting | Commit touched | Plan started |
  |---|---|---|
  | Always trigger runs | nothing (empty commit) | yes |
  | pattern `/infra/**` (typed in the UI) | `infra/host/` | no |
  | pattern `infra/**/*` (the UI's hint form) | `infra/host/` | **yes** |
  | "Prefixes" `infra/host/`, `infra/otel/`, `infra/terraform/modules/` | `infra/host/` | no |
  | (same) | `infra/bootstrap/` | no |

- **Cause:** a trigger pattern must name files, ending in `/*`, without a leading slash (the
  UI's hint is `foo/**/*`). `infra/**` (the original) and `/infra/**` (yesterday's PR #29, an
  unverified fix based on the docs' examples) matched nothing. The GitHub connection was never
  at fault. The "prefixes" row did not test prefixes: the API afterwards showed the UI had saved
  them as trigger *patterns* (`infra/host/`, which names a directory, not files), with
  `trigger-prefixes` empty. So it failed for the same reason; real prefixes were never tried.
- **Done:** each workspace watches what its root reads, as `…/**/*` patterns: its own root,
  `infra/terraform/modules/`, `infra/host/`, and for the environments `infra/otel/`.
  Bootstrap/test changes no longer queue runs. Prefixes are cleared. A new test reads each root's
  `.tf` files, the modules they source and the files passed to `file()`/`templatefile()`, and
  fails if any is outside that workspace's patterns (shown by removing `infra/otel/**/*`).
- **Corrections:** PR #29's "leading slash" diagnosis was wrong. Earlier "Terraform Cloud
  pass 0" checks were read as "0 runs"; the 0 was the check's duration. The workspace runs API
  query used here does not list speculative plans.

**Next task:** operator reruns step 2 from this branch, then two scratch pushes on #32 prove
the patterns (`infra/host/` → plans in all three workspaces; `infra/bootstrap/` → none).
- **Verified before merge** (operator ran step 2 from this branch; all three workspaces got
  their patterns, `acme_ca` untouched): a PR touching `infra/host/` started plans in all three
  workspaces ("0 of 3 complete"); a fresh PR touching only `infra/bootstrap/` (#34) started
  none. A PR's plans follow every file the PR changes against `main`, not just its latest
  commit, so a negative test needs its own PR.
- **Docs:** runbook step 2 "Reruns" now explains settings (restored on rerun) vs variables
  (owned by the operator after bootstrap) and lists which variables change later and how;
  contracts/workspace-variables.md has the same as "Who owns a variable after bootstrap".
- **Gap found:** no runbook procedure rotates `openobserve_db_password_version`. Bumping it
  would change SSM but not OpenObserve's Postgres. Marked "don't bump" in the contract until a
  procedure exists.

### 2026-10-27: infra/host README (also deploys #26 and #30)

- **Done:** `infra/host/README.md` maps each host file to its place on the host, which hosts get
  it and what it does, and says that editing a passed file replaces hosts.
- **Why now:** it is under `infra/host/`, so its merge queues runs in all three workspaces
  through the new trigger patterns. It is not passed to hosts, so those runs plan only what was
  waiting: #26's swap file and #30's Collector `GOMEMLIMIT`, which replace each host (data, IP
  and certificates kept). First real proof of runs starting from a merge to `main`.

**Next task:** confirm the shared-us and prod-us runs, check dev-staging's `/healthz` after its
replacement (same version), then the `/healthz` timestamps.

### 2026-10-27: environment hosts on t4g.micro

- **Done:** the environment root's `instance_type` default is now `t4g.micro` (1 GiB), so
  dev-staging and prod-us both move down one size on their next apply (host replacement; data,
  IP and certificates kept). The telemetry host stays `t4g.small` (OpenObserve peaked at
  949 MiB). Research R4/R5, the variables contract, data model, plan, README and runbook
  updated; estimated cost drops from ≈ $55 to ≈ $43 a month.
- **Decision:** operator chose to move both environments at once instead of the staging-first
  trial the runbook described. Basis: measured ~700–750 MiB peak plus the 1 GiB swap file
  (#26) and the Collector's `GOMEMLIMIT` (#30). The runbook now says how to check memory after
  a deploy and how to put one workspace back on `t4g.small` by setting the variable there.

**Next task:** after the merge, confirm prod-us's run (dev-staging auto-applies), deploy, and
check `free -m` / `swapon --show` on both hosts.
### 2026-10-27: /healthz reports time and started_at

- **Done (test first):** `/healthz` and `/healthz/live` add `time` (current UTC time, from
  `MockPms::Clock`, so tests can freeze it) and `started_at` (when the web process loaded, from
  the system clock). Four new examples failed before the change. The 001 OpenAPI contract and
  002 host-interface contract describe both; host-interface now says `version` is the full commit
  SHA the image was built from.
- **Answered:** `version` is that build SHA, not necessarily `main`'s latest commit.
- **Tests:** RSpec 175 examples, 0 failures; RuboCop clean (five offenses this change introduced
  were fixed). Consumers (`rentsync-deploy`, the Deploy workflow) read single fields, so the new
  fields change nothing for them.

**Next task:** merge, then Deploy to dev-staging and prod-us to see the new fields live.
- **Added (operator request):** `time_ct` and `started_at_ct`, the same times in US Central
  (`2026-10-27 07:00:05 CDT`). `MockPms::CentralTime` writes the US daylight-time rule locally
  (second Sunday of March to first Sunday of November, 2:00 local) instead of adding a time zone
  gem (constitution VIII). Specs cover both seasons, a date rollover and both switch instants in
  two years; moving the March switch to the first Sunday fails them. Full suite: 182 examples,
  0 failures; RuboCop clean. Demo-specific: the zone is fixed to US Central.

### 2026-10-27: telemetry volume (scrape interval and retention)

- **Why:** OpenObserve showed ~1.6M events. Nearly all are metric rows: one per series per
  scrape, with a row per histogram bucket, route and status, scraped every 15 s on two hosts.
  Storage was small (~10 MB compressed) but OpenObserve had no retention set (default ~10 years).
- **Done:** `infra/otel/collector.yaml` reads `scrape_interval` from `METRICS_SCRAPE_INTERVAL`
  (default 15s); `infra/host/compose.env.yaml` sets 60s on deployed hosts (a quarter of the
  rows). `compose.telemetry.yaml` sets `ZO_COMPACT_DATA_RETENTION_DAYS: "30"` (name checked in
  the v1.0.4 binary). Verified with `otelcol validate`: unset → 15s, `60s` accepted, `bogus`
  rejected, so the variable is really read.
- **Decision:** local and CI keep 15 s, because the telemetry smoke test waits only 60 s for a
  Collector self-metric that needs a second scrape after the first log export.
- **Effect on merge:** files under `infra/host/` and `infra/otel/` change, so all three hosts
  are replaced (data, IP and certificates kept).

**Next task:** after apply, confirm the event rate in OpenObserve drops to about a quarter.

### 2026-10-27: OpenObserve database password rotation (issue #35)

- **Done:** `infra/host/bin/rentsync-start` (telemetry) now renders secrets, starts only
  `openobserve-db`, runs `ALTER USER openobserve PASSWORD '<SSM value>'` through `psql` on stdin
  over the container's local socket, then starts the rest. Rotation is: bump
  `openobserve_db_password_version`, apply, `systemctl restart rentsync.service`. A reboot or
  host replacement does the same. Runbook §Secret rotation, the variables contract and research
  R11 updated; the "don't bump" note is gone.
- **Tests:** new `infra/host/test/start_test.sh` (stub docker): step order, the statement on
  stdin, the password never in argv, a failed `ALTER USER` stops the start before OpenObserve,
  no stack file, environment role, unknown role. Mutations caught: the old script, and the
  password passed with `-c`. Rehearsed with real Docker Compose and `postgres:16`: first start,
  rotation (old password refused over the network, new accepted), restart with no change.
- **Decision:** a failed `ALTER USER` fails the start rather than starting OpenObserve with a
  DSN Postgres would refuse; systemd shows the failure. The environment Postgres procedure is
  still manual; the same approach could move into `rentsync-deploy --reload` later.

**Next task:** after merge and apply, the telemetry host is replaced (a host file changed); its
start runs the new step with the unchanged password, a no-op. Rotate once to prove it live.

### 2026-10-27: releases wait for a host being replaced

- **Why:** #39's merge started an HCP host replacement and the auto-release together; the
  dev-staging deploy reached the old host as it shut down ("status: Failed", no output), and
  the new host booted on the previous image.
- **Done:** the SSM send/poll logic moved from `deploy-to.yml` into
  `infra/release/run-deploy.sh` (the job now checks out the repo). The host runs
  `cloud-init status --wait` before `rentsync-deploy`, because a new host has the deploy
  script before Docker. The command is resent every 30 s, up to 25 minutes, while no host is
  tagged or the host didn't finish (any exit code `rentsync-deploy` never uses). Its own
  outcomes (0, 1, 2, 3, 64, 75) are final. No IAM change: only SendCommand,
  ListCommandInvocations and GetCommandInvocation are used.
- **Tests:** `infra/release/test/run_deploy_test.sh` (stub aws): first-time success, killed
  host then success, no host then success, rollback not retried, deadline. Mutations caught:
  no retry, and retrying a rollback. Added to `infra/test/run.sh` and CI's shellcheck.
- **Not proven live yet:** the exit code SSM reports for a host killed mid-command is assumed
  to be outside rentsync-deploy's set (SSM uses -1 for an interrupted command).

**Next task:** the next merge that touches `infra/host/` is the live test; the release log
should show "trying again" and then success on the new host.
## Entries by PR

<!-- One slot per PR number, filled by `ruby bin/build-log fill <pr>`; see the top of this file. -->

<!-- PR #42 -->
### 2026-10-27: build-log slots (interactive)

- **Why:** every PR appended to the end of this file, so the second of any two open PRs
  always conflicted and needed a manual merge of `main`.
- **Done:** the log now ends with one slot per PR number (#42 to #1041, HTML comments that
  don't render). `ruby bin/build-log fill <pr>` writes an entry into its own slot; GitHub
  never reuses a number, so two PRs never touch the same lines. `check` runs in CI (slot
  order, empty free slots, a `###` heading on filled ones; warns below 100 free) and
  `top-up` adds slots back to 1000. Plain Ruby, LF output on every platform.
- **Tests:** `bin/test/build_log_test.rb`, including a real `git merge` of two branches that
  fill neighbouring slots. A scratch-repo experiment first confirmed neighbouring slots merge
  cleanly and a shared slot conflicts, which is why slots are keyed by PR number rather than
  "first free".
- **Decisions:** operator chose slots in one file over one file per entry or a
  `.gitattributes` union merge (GitHub ignores merge drivers when checking PRs). 1000 slots
  instead of 100, at the operator's request, so top-ups are years away. Constitution 1.7.1
  (PATCH): entries go in the PR's slot; `CLAUDE.md` matches.

**Next task:** write every later entry with `ruby bin/build-log fill <pr>` after opening the PR.

<!-- PR #43: free -->

<!-- PR #44: free -->

<!-- PR #45: free -->

<!-- PR #46: free -->

<!-- PR #47: free -->

<!-- PR #48: free -->

<!-- PR #49 -->
### 2026-10-28: 002 live quickstart checks, agent-run part (background agent)

- **Done:**
  - Ran the checks that need no credentials against the live hosts:
    - `nmap` over all TCP ports on the three public IPs: only 80 and 443 open;
    - quickstart §3 on dev-staging and prod-us: `/healthz` ok on `c5ccd8d`, 308 to HTTPS, `/metrics` 404, `/admin` 401;
    - all three certificates from Let's Encrypt production;
    - anonymous telemetry visit: the API returns 401;
    - `gitleaks` over `main`: 11 matches, all deliberate test values.
  - Recorded these as notes on T055, T065, T071 and T089. No task is fully done, so none are ticked.
- **Blocked:** the local AWS CLI is signed in to a different account, not RentSync's, and there's no HCP token locally. Everything needing AWS, HCP or the admin tokens therefore stays with the operator:
  - SSM, `chronyc` and the tag audit;
  - searching the state and run logs for secrets;
  - the feature 001 §4 checks;
  - the OpenObserve sign-in checks;
  - the reboot, DLM snapshots and budget check.
  No changes were made through the AWS CLI.
- **Decisions:** none.
- **Next task:** the operator issues for the remaining live checks; then T091a summarizes the results.

<!-- PR #50: free -->

<!-- PR #51 -->
### 2026-10-28: operator CLI role (interactive)

- **Why:** the AWS-side live checks (#44, #45, #50) need AWS CLI access from the operator's
  machine, whose default profile is a different AWS account. The operator asked whether a
  temporary access key would do. It would break 002's "no long-lived AWS key" checks, so this
  adds a role that an `aws login` profile assumes instead.
- **Done:** `infra/bootstrap/bootstrap-operator.sh` (CloudShell; plan, `--apply`,
  `--teardown`) creates `rentsync-operator` from `docs/deploy/iam/operator/`. Permissions:
  `ReadOnlyAccess`, SSM sessions and `AWS-RunShellScript` on `DeploymentId`-tagged hosts, and
  decryption of `admin_token` parameters only. It trusts exactly the identity running it; an
  assumed role by its real ARN, and the root user refused. Sessions last at most one hour.
  Runbook §Operator CLI access, a §Bootstrap teardown step, and a 002 contract section.
- **Tests:** `bootstrap_operator_test.sh` (stub `aws`) is in `infra/test/run.sh` and CI's
  bash-version check. Two deliberate mutations failed it as expected: a 12-hour session, and
  a reboot action in the policy. Full suite green.
- **Decisions:** the operator chose option B (`aws login` plus a narrow role) over IAM Identity
  Center. Host shells are root-capable, which the PR and runbook say plainly.
- **Next:** the operator runs the script in CloudShell. Claude adds the local profiles, and
  confirms the AWS account with `sts get-caller-identity --profile rentsync`, before any check.

<!-- PR #52 -->
### 2026-10-28: HCP secret audit script (interactive)

- **Why:** #50's "no secret in HCP state or run logs" check (SC-004, FR-024) needs HCP
  access. HCP Terraform's Free plan has no read-only token (every member is an owner), so
  the read-only limit has to live in the client.
- **Done:** `infra/bootstrap/audit-hcp-secrets.rb`. Its transport sends only GET requests,
  and the token goes only to HCP's hosts. It reads every state version and every plan and
  apply log of the three workspaces into memory, and reports only names and locations.
  - **By value:** secrets read from SSM (`--aws-profile`, default `rentsync`, which can
    decrypt only the admin tokens), searched in state, decoded gzipped user data and logs.
  - **By attribute:** a SecureString value or a managed random result in state fails.
  - **Notes, not failures:** other sensitive attributes, and literal secret-looking
    assignments in the logs.
  - Linked from quickstart §2 and §9 and from runbook §Secret rotation. CI runs its test.
- **Decision:** the operator runs it (`! ruby …`) instead of me holding their full-rights
  `terraform login` token. The script is written so that either is safe to review.
- **Tests:** 11 minitest cases against a fake HCP. Six mutations of the script were each
  caught. RSpec 182/0, the infra tests, the bootstrap-HCP test and the build-log check pass.
- **Blocked / next:** the operator runs it against the real HCP and records the result on
  #50. Values rotated away before the run can't be searched for by value.

<!-- PR #53: free -->

<!-- PR #54 -->
### 2026-10-28: 003 Phases 1 and 2, the API foundation (interactive)

- **Done:** T001–T024.
  - **Phase 1:** a new `api/` service with the mock's six runtime gems, one image for web and
    worker, Compose services, `.env.example` settings, and a CI `api` job.
  - **Phase 2:**
    - test-first settings and AES-256-GCM `Crypto::Box`;
    - logging, metrics and middleware copied from the mock (R1), with the new secret keys
      redacted;
    - migration 001 and models whose encrypted columns are bound to
      `<table>.<column>:<id>`;
    - `Pms::Registration` (register, keep, or supersede, under an advisory lock) and
      `install!` for credentials handed over out of band;
    - `bin/setup`, `bin/pms_client` and `bin/worker` (metrics on 4003, clean SIGTERM);
    - `/healthz` and `/metrics`.
- **Tests:** 110 examples on Ruby 4.0 and 3.3; RuboCop clean. Two mutation checks were
  caught: removing the advisory lock makes two registrations collide, and the T010/T011
  specs failed before their code existed. Locally, the API registered with the real mock,
  a rerun kept the client, and `/healthz` is ok with the worker's heartbeat.
- **Decisions:**
  - The image uses `ruby:4.0-slim` like the mock's, not the 3.3 that T002 names.
  - On a mock reset, only live connections go to `needs_reauth` (as data-model.md says),
    not disconnected ones.
  - Worker examples that run threads are `:committed`, because their heartbeats commit on
    another connection.
  - `spec_helper` forces its test settings so a developer's `.env` can't change results.
- **Gotchas:** Ruby text-mode writes on Windows produced CRLF files (fixed; now in memory),
  and `core.filemode=false` committed the scripts without the executable bit (fixed).
- **Local setup:** the operator's `.env` gained the 13 new settings from `.env.example`
  (backup in the session scratchpad).
- **Next:** Phase 3 (US1, connect a PMS account), T025 onward.

### 2026-10-29: 003 Phase 3, US1 connect a PMS account (interactive)

- **Done:** T025–T035.
  - **Mock:** token responses now carry `operator_id` and `operator_name`, and 001's
    `TokenResponse` schema is updated to match.
  - **API:**
    - operator sign-in, with sessions, CSRF tokens and a sign-in throttle;
    - the PKCE connect flow with single-use state;
    - renewal under a lease;
    - pages plus the `/v1/connections` JSON alias;
    - `bin/connect_operator`;
    - the daily purge.
- **Tests:** 172 API examples, and the mock suite, pass; RuboCop is clean.
  - The four new specs failed first: the mock spec on the missing fields, the API specs on the
    missing code.
  - **Mutation checks** caught each of these removals:
    - the renewal lease;
    - the lease's "still needs renewing" condition;
    - `invalid_client` sending a connection to reauthorization;
    - idle expiry;
    - operator scoping on the list and on single connections;
    - the state owner check and single use;
    - CSRF on disconnect;
    - the `Secure` cookie flag.
- **Live checks, local:**
  - `bin/connect_operator` connected operator 1 to the real mock. A deny stored nothing, and
    a reconnect reused the row.
  - A forced renewal got a fresh token from the mock.
  - The logs hold no tokens, codes or passwords.
  - The purge ran once under its lease.
- **Decisions:**
  - **Renewal:** the backoff (5 s doubling to 300 s) is kept in `renewal_lease_until`.
    Refusals other than `invalid_grant`/`invalid_client` count as temporary.
  - **A second PMS account:** for the same RentSync operator it is refused as
    `different_pms_account`, because `(operator_id, pms_client_id)` is unique.
  - **The pages** are a Grape API, so they get route-template metric labels.
  - **The seed** mirrors the mock's fixed three operators, because the mock's admin API has no
    operator list.
  - **Approvals:** the operator approved T002's Ruby 4.0 image and T020's live-only
    `needs_reauth`.
- **Found and fixed:** `api` and `api_worker` ran a stale image with no source mount. That
  made the suite flaky against the dev database. `compose.override.yaml` now mounts `api/`,
  as it already does `mock_pms/`.
- **Not fixed:** the mock suite doesn't load on Ruby 4.0. `chaos/decider_spec.rb` requires
  `benchmark`, which 4.0 no longer ships by default. CI's 3.3 run is unaffected.
- **Open from the checkpoint:** quickstart §2 steps 4 and 5 need **Reconcile now** (US3).
  Step 6's health URL needs US4.
- **Next:** Phase 4 (US2, record every PMS event exactly once), T036 onward.

### 2026-10-29: 003 Phase 4, US2 record every PMS event exactly once (interactive)

- **Done:** T036–T046.
  - **Receiver:** `POST /webhooks/pms` is a plain Rack endpoint. It reads at most 256 KiB, checks
    the signature (constant time, then the 300 s window) before reading the body, then the
    envelope.
  - **Recording:** the raw event and its receipt are written in one transaction.
    `ON CONFLICT DO NOTHING` covers the event-ID key and the partial business-key key, and a
    trigger refuses `UPDATE` and `DELETE` on `raw_events`.
  - **Tools:** `/admin/raw_events`, `/admin/receipts` and `bin/send_test_webhook`.
  - **Metrics:** receipts, raw events, and the acknowledgement-time histogram.
  - **ADR 0011.**
- **Tests:** 238 API examples pass; RuboCop is clean.
  - Every new spec was seen failing first.
  - The end-to-end spec is `:committed` and runs on a real local Puma, so "200 only after
    commit" is a real commit.
  - **Mutation checks** caught each of these:
    - dropping the digest comparison;
    - accepting any connection status;
    - skipping the size limit.
- **Live check, local, chaos on (quickstart §3 settings) with a `month_end_burst`:**
  - 22 events reached RentSync across 28 deliveries; 21 were recorded, with 0 duplicated;
  - all 27 malformed deliveries were rejected, and 4 repeats got `duplicate`;
  - the one event still missing had only a malformed delivery, and US3's reconciliation will
    recover it.
  - Chaos was reset to 0 afterwards.
- **Decisions:**
  - **500 receipts:** a 500 writes an `internal_error` receipt after the rollback. This is a
    new reason; data-model.md and the contract are updated.
  - **Signing secret:** only the active PMS client's secret is accepted, so a superseded
    registration's deliveries get `bad_signature`.
  - **Correlation ID:** `X-Correlation-Id` now wins over `X-Request-Id`, so a proxy's ID
    can't replace the PMS's. The ID is stored before any authentication, so only short
    plain tokens (`\A[\w.:-]{1,128}\z`) are kept; anything else gets a generated ID. The
    mock's middleware keeps the old order.
  - **Disconnect:** the Phase 3 spec now asserts that disconnecting keeps raw events. The
    assertion passed when first run.
  - **Admin token:** `/admin` reuses the mock's `ADMIN_TOKEN` value, so the hosts need no new
    secret (plan.md).
  - **Test sender:** `bin/send_test_webhook` refuses a valid delivery without `--record`,
    because raw events are permanent.
  - **Histogram buckets:** the shared buckets gain 2 s, so SC-006's p95 is read off a bucket.
    `buffer_spec`'s pinned list was updated on purpose.
- **Login CSRF (the operator asked for it):** `POST /sign-in` refuses cross-site posts
  (by `Sec-Fetch-Site` or `Origin`) with 403, before the throttle. Clients that send neither
  header are still allowed. Checked live; research R11 updated.
- **Next:** Phase 5 (US3, reconciliation), T047 onward.

### 2026-10-29: 003 Phase 5, US3 catch what webhooks missed (interactive)

- **Done:** T047–T057.
  - **`Pms::Client`:**
    - every call takes a token from a Redis bucket keyed on the PMS client;
    - a 429 sets a `blocked_until` that every instance obeys (a Lua compare-and-set);
    - full-jitter backoff on 429s, 5xx and timeouts, giving up after 6 attempts;
    - it fails closed without Redis;
    - a 401 forces one renewal.
  - **`Reconciliation::Run`:**
    - walks `/v1/payments` from the watermark minus the overlap, or everything the first time;
    - records `payment.created` and `payment.reversed` facts with synthetic IDs;
    - saves the cursor with each page's facts;
    - resumes after a kill;
    - backs off 30 s, doubling up to the interval.
  - **`Reconciliation::Scheduler`:** claims due connections with `FOR UPDATE SKIP LOCKED`
    under a lease.
  - **Also:** the **Reconcile now** button and route, the 90-day receipt purge,
    `bin/compare_with_pms`, four metrics, and ADR 0009.
- **Tests:** 278 API examples pass; RuboCop is clean.
  - Every new spec was seen failing first.
  - **Mutation checks** caught each of these:
    - dropping `SKIP LOCKED`;
    - dropping the status filter;
    - not saving the cursor;
    - not reading the shared block, and not setting it.
- **Checkpoint, local (details in tasks.md):**
  - §3 with chaos on: clean (0 missing, 0 duplicated).
  - §4.1: lost webhooks were recovered by reconciliation, and replays of them came back as
    `duplicate` with `reconciliation`.
  - §4.3: ten 429s at a 10-a-minute limit, all honoured, and every run succeeded.
  - §4.5: two workers never ran one connection at once.
  - Quickstart §2 steps 4 and 5 now pass: a revoked grant goes to `needs_reauth`, and
    reconnecting keeps the row.
  - §4.4 was covered only by `run_spec`, because a backfill takes 0.67 s.
- **Decisions:**
  - **Reconcile now:** migration 004 adds `pms_connections.reconcile_requested_at`, so a run
    is named `manual` and a press during a run is not lost. The foreign key that 003 promised
    is added too.
  - **Payment time:** a reconciled `payment.created` uses the payment's own `received_at` as
    `occurred_at`, the same time as the PMS's webhook.
  - **Watermark after a resumed walk:** it is the earliest start since the last success.
  - **409:** only for `needs_reauth` and `disconnected`. `renewal_failing` is still reconciled.
  - **`compare_with_pms`:** compares payments by business key, and lease events only when they
    were delivered to RentSync. It reads RentSync's side from the database.
  - **Redirect:** Reconcile now redirects to `/connections` until the health page (US4)
    exists.
- **Local state:**
  - all three seeded operators are connected, with their histories backfilled permanently;
  - one worker again;
  - chaos is 0, and the mock client's rate limit is back to the default.
- **Clock fix (the operator asked for it):** the shared Retry-After block now uses the Redis
  server's clock, as the bucket does, so containers on hosts whose clocks differ agree on when
  it ends. Specs can still drive it through an optional `now_ms`. Checked live: at 3 a minute,
  a backfill waited out 4 blocks (40 s) and succeeded.
- **Next:** Phase 6 (US4, connection health), T058 onward.

<!-- PR #55: free -->

<!-- PR #56: free -->

<!-- PR #57: free -->

<!-- PR #58: free -->

<!-- PR #59: free -->

<!-- PR #60: free -->

<!-- PR #61: free -->

<!-- PR #62: free -->

<!-- PR #63: free -->

<!-- PR #64: free -->

<!-- PR #65: free -->

<!-- PR #66: free -->

<!-- PR #67: free -->

<!-- PR #68: free -->

<!-- PR #69: free -->

<!-- PR #70: free -->

<!-- PR #71: free -->

<!-- PR #72: free -->

<!-- PR #73: free -->

<!-- PR #74: free -->

<!-- PR #75: free -->

<!-- PR #76: free -->

<!-- PR #77: free -->

<!-- PR #78: free -->

<!-- PR #79: free -->

<!-- PR #80: free -->

<!-- PR #81: free -->

<!-- PR #82: free -->

<!-- PR #83: free -->

<!-- PR #84: free -->

<!-- PR #85: free -->

<!-- PR #86: free -->

<!-- PR #87: free -->

<!-- PR #88: free -->

<!-- PR #89: free -->

<!-- PR #90: free -->

<!-- PR #91: free -->

<!-- PR #92: free -->

<!-- PR #93: free -->

<!-- PR #94: free -->

<!-- PR #95: free -->

<!-- PR #96: free -->

<!-- PR #97: free -->

<!-- PR #98: free -->

<!-- PR #99: free -->

<!-- PR #100: free -->

<!-- PR #101: free -->

<!-- PR #102: free -->

<!-- PR #103: free -->

<!-- PR #104: free -->

<!-- PR #105: free -->

<!-- PR #106: free -->

<!-- PR #107: free -->

<!-- PR #108: free -->

<!-- PR #109: free -->

<!-- PR #110: free -->

<!-- PR #111: free -->

<!-- PR #112: free -->

<!-- PR #113: free -->

<!-- PR #114: free -->

<!-- PR #115: free -->

<!-- PR #116: free -->

<!-- PR #117: free -->

<!-- PR #118: free -->

<!-- PR #119: free -->

<!-- PR #120: free -->

<!-- PR #121: free -->

<!-- PR #122: free -->

<!-- PR #123: free -->

<!-- PR #124: free -->

<!-- PR #125: free -->

<!-- PR #126: free -->

<!-- PR #127: free -->

<!-- PR #128: free -->

<!-- PR #129: free -->

<!-- PR #130: free -->

<!-- PR #131: free -->

<!-- PR #132: free -->

<!-- PR #133: free -->

<!-- PR #134: free -->

<!-- PR #135: free -->

<!-- PR #136: free -->

<!-- PR #137: free -->

<!-- PR #138: free -->

<!-- PR #139: free -->

<!-- PR #140: free -->

<!-- PR #141: free -->

<!-- PR #142: free -->

<!-- PR #143: free -->

<!-- PR #144: free -->

<!-- PR #145: free -->

<!-- PR #146: free -->

<!-- PR #147: free -->

<!-- PR #148: free -->

<!-- PR #149: free -->

<!-- PR #150: free -->

<!-- PR #151: free -->

<!-- PR #152: free -->

<!-- PR #153: free -->

<!-- PR #154: free -->

<!-- PR #155: free -->

<!-- PR #156: free -->

<!-- PR #157: free -->

<!-- PR #158: free -->

<!-- PR #159: free -->

<!-- PR #160: free -->

<!-- PR #161: free -->

<!-- PR #162: free -->

<!-- PR #163: free -->

<!-- PR #164: free -->

<!-- PR #165: free -->

<!-- PR #166: free -->

<!-- PR #167: free -->

<!-- PR #168: free -->

<!-- PR #169: free -->

<!-- PR #170: free -->

<!-- PR #171: free -->

<!-- PR #172: free -->

<!-- PR #173: free -->

<!-- PR #174: free -->

<!-- PR #175: free -->

<!-- PR #176: free -->

<!-- PR #177: free -->

<!-- PR #178: free -->

<!-- PR #179: free -->

<!-- PR #180: free -->

<!-- PR #181: free -->

<!-- PR #182: free -->

<!-- PR #183: free -->

<!-- PR #184: free -->

<!-- PR #185: free -->

<!-- PR #186: free -->

<!-- PR #187: free -->

<!-- PR #188: free -->

<!-- PR #189: free -->

<!-- PR #190: free -->

<!-- PR #191: free -->

<!-- PR #192: free -->

<!-- PR #193: free -->

<!-- PR #194: free -->

<!-- PR #195: free -->

<!-- PR #196: free -->

<!-- PR #197: free -->

<!-- PR #198: free -->

<!-- PR #199: free -->

<!-- PR #200: free -->

<!-- PR #201: free -->

<!-- PR #202: free -->

<!-- PR #203: free -->

<!-- PR #204: free -->

<!-- PR #205: free -->

<!-- PR #206: free -->

<!-- PR #207: free -->

<!-- PR #208: free -->

<!-- PR #209: free -->

<!-- PR #210: free -->

<!-- PR #211: free -->

<!-- PR #212: free -->

<!-- PR #213: free -->

<!-- PR #214: free -->

<!-- PR #215: free -->

<!-- PR #216: free -->

<!-- PR #217: free -->

<!-- PR #218: free -->

<!-- PR #219: free -->

<!-- PR #220: free -->

<!-- PR #221: free -->

<!-- PR #222: free -->

<!-- PR #223: free -->

<!-- PR #224: free -->

<!-- PR #225: free -->

<!-- PR #226: free -->

<!-- PR #227: free -->

<!-- PR #228: free -->

<!-- PR #229: free -->

<!-- PR #230: free -->

<!-- PR #231: free -->

<!-- PR #232: free -->

<!-- PR #233: free -->

<!-- PR #234: free -->

<!-- PR #235: free -->

<!-- PR #236: free -->

<!-- PR #237: free -->

<!-- PR #238: free -->

<!-- PR #239: free -->

<!-- PR #240: free -->

<!-- PR #241: free -->

<!-- PR #242: free -->

<!-- PR #243: free -->

<!-- PR #244: free -->

<!-- PR #245: free -->

<!-- PR #246: free -->

<!-- PR #247: free -->

<!-- PR #248: free -->

<!-- PR #249: free -->

<!-- PR #250: free -->

<!-- PR #251: free -->

<!-- PR #252: free -->

<!-- PR #253: free -->

<!-- PR #254: free -->

<!-- PR #255: free -->

<!-- PR #256: free -->

<!-- PR #257: free -->

<!-- PR #258: free -->

<!-- PR #259: free -->

<!-- PR #260: free -->

<!-- PR #261: free -->

<!-- PR #262: free -->

<!-- PR #263: free -->

<!-- PR #264: free -->

<!-- PR #265: free -->

<!-- PR #266: free -->

<!-- PR #267: free -->

<!-- PR #268: free -->

<!-- PR #269: free -->

<!-- PR #270: free -->

<!-- PR #271: free -->

<!-- PR #272: free -->

<!-- PR #273: free -->

<!-- PR #274: free -->

<!-- PR #275: free -->

<!-- PR #276: free -->

<!-- PR #277: free -->

<!-- PR #278: free -->

<!-- PR #279: free -->

<!-- PR #280: free -->

<!-- PR #281: free -->

<!-- PR #282: free -->

<!-- PR #283: free -->

<!-- PR #284: free -->

<!-- PR #285: free -->

<!-- PR #286: free -->

<!-- PR #287: free -->

<!-- PR #288: free -->

<!-- PR #289: free -->

<!-- PR #290: free -->

<!-- PR #291: free -->

<!-- PR #292: free -->

<!-- PR #293: free -->

<!-- PR #294: free -->

<!-- PR #295: free -->

<!-- PR #296: free -->

<!-- PR #297: free -->

<!-- PR #298: free -->

<!-- PR #299: free -->

<!-- PR #300: free -->

<!-- PR #301: free -->

<!-- PR #302: free -->

<!-- PR #303: free -->

<!-- PR #304: free -->

<!-- PR #305: free -->

<!-- PR #306: free -->

<!-- PR #307: free -->

<!-- PR #308: free -->

<!-- PR #309: free -->

<!-- PR #310: free -->

<!-- PR #311: free -->

<!-- PR #312: free -->

<!-- PR #313: free -->

<!-- PR #314: free -->

<!-- PR #315: free -->

<!-- PR #316: free -->

<!-- PR #317: free -->

<!-- PR #318: free -->

<!-- PR #319: free -->

<!-- PR #320: free -->

<!-- PR #321: free -->

<!-- PR #322: free -->

<!-- PR #323: free -->

<!-- PR #324: free -->

<!-- PR #325: free -->

<!-- PR #326: free -->

<!-- PR #327: free -->

<!-- PR #328: free -->

<!-- PR #329: free -->

<!-- PR #330: free -->

<!-- PR #331: free -->

<!-- PR #332: free -->

<!-- PR #333: free -->

<!-- PR #334: free -->

<!-- PR #335: free -->

<!-- PR #336: free -->

<!-- PR #337: free -->

<!-- PR #338: free -->

<!-- PR #339: free -->

<!-- PR #340: free -->

<!-- PR #341: free -->

<!-- PR #342: free -->

<!-- PR #343: free -->

<!-- PR #344: free -->

<!-- PR #345: free -->

<!-- PR #346: free -->

<!-- PR #347: free -->

<!-- PR #348: free -->

<!-- PR #349: free -->

<!-- PR #350: free -->

<!-- PR #351: free -->

<!-- PR #352: free -->

<!-- PR #353: free -->

<!-- PR #354: free -->

<!-- PR #355: free -->

<!-- PR #356: free -->

<!-- PR #357: free -->

<!-- PR #358: free -->

<!-- PR #359: free -->

<!-- PR #360: free -->

<!-- PR #361: free -->

<!-- PR #362: free -->

<!-- PR #363: free -->

<!-- PR #364: free -->

<!-- PR #365: free -->

<!-- PR #366: free -->

<!-- PR #367: free -->

<!-- PR #368: free -->

<!-- PR #369: free -->

<!-- PR #370: free -->

<!-- PR #371: free -->

<!-- PR #372: free -->

<!-- PR #373: free -->

<!-- PR #374: free -->

<!-- PR #375: free -->

<!-- PR #376: free -->

<!-- PR #377: free -->

<!-- PR #378: free -->

<!-- PR #379: free -->

<!-- PR #380: free -->

<!-- PR #381: free -->

<!-- PR #382: free -->

<!-- PR #383: free -->

<!-- PR #384: free -->

<!-- PR #385: free -->

<!-- PR #386: free -->

<!-- PR #387: free -->

<!-- PR #388: free -->

<!-- PR #389: free -->

<!-- PR #390: free -->

<!-- PR #391: free -->

<!-- PR #392: free -->

<!-- PR #393: free -->

<!-- PR #394: free -->

<!-- PR #395: free -->

<!-- PR #396: free -->

<!-- PR #397: free -->

<!-- PR #398: free -->

<!-- PR #399: free -->

<!-- PR #400: free -->

<!-- PR #401: free -->

<!-- PR #402: free -->

<!-- PR #403: free -->

<!-- PR #404: free -->

<!-- PR #405: free -->

<!-- PR #406: free -->

<!-- PR #407: free -->

<!-- PR #408: free -->

<!-- PR #409: free -->

<!-- PR #410: free -->

<!-- PR #411: free -->

<!-- PR #412: free -->

<!-- PR #413: free -->

<!-- PR #414: free -->

<!-- PR #415: free -->

<!-- PR #416: free -->

<!-- PR #417: free -->

<!-- PR #418: free -->

<!-- PR #419: free -->

<!-- PR #420: free -->

<!-- PR #421: free -->

<!-- PR #422: free -->

<!-- PR #423: free -->

<!-- PR #424: free -->

<!-- PR #425: free -->

<!-- PR #426: free -->

<!-- PR #427: free -->

<!-- PR #428: free -->

<!-- PR #429: free -->

<!-- PR #430: free -->

<!-- PR #431: free -->

<!-- PR #432: free -->

<!-- PR #433: free -->

<!-- PR #434: free -->

<!-- PR #435: free -->

<!-- PR #436: free -->

<!-- PR #437: free -->

<!-- PR #438: free -->

<!-- PR #439: free -->

<!-- PR #440: free -->

<!-- PR #441: free -->

<!-- PR #442: free -->

<!-- PR #443: free -->

<!-- PR #444: free -->

<!-- PR #445: free -->

<!-- PR #446: free -->

<!-- PR #447: free -->

<!-- PR #448: free -->

<!-- PR #449: free -->

<!-- PR #450: free -->

<!-- PR #451: free -->

<!-- PR #452: free -->

<!-- PR #453: free -->

<!-- PR #454: free -->

<!-- PR #455: free -->

<!-- PR #456: free -->

<!-- PR #457: free -->

<!-- PR #458: free -->

<!-- PR #459: free -->

<!-- PR #460: free -->

<!-- PR #461: free -->

<!-- PR #462: free -->

<!-- PR #463: free -->

<!-- PR #464: free -->

<!-- PR #465: free -->

<!-- PR #466: free -->

<!-- PR #467: free -->

<!-- PR #468: free -->

<!-- PR #469: free -->

<!-- PR #470: free -->

<!-- PR #471: free -->

<!-- PR #472: free -->

<!-- PR #473: free -->

<!-- PR #474: free -->

<!-- PR #475: free -->

<!-- PR #476: free -->

<!-- PR #477: free -->

<!-- PR #478: free -->

<!-- PR #479: free -->

<!-- PR #480: free -->

<!-- PR #481: free -->

<!-- PR #482: free -->

<!-- PR #483: free -->

<!-- PR #484: free -->

<!-- PR #485: free -->

<!-- PR #486: free -->

<!-- PR #487: free -->

<!-- PR #488: free -->

<!-- PR #489: free -->

<!-- PR #490: free -->

<!-- PR #491: free -->

<!-- PR #492: free -->

<!-- PR #493: free -->

<!-- PR #494: free -->

<!-- PR #495: free -->

<!-- PR #496: free -->

<!-- PR #497: free -->

<!-- PR #498: free -->

<!-- PR #499: free -->

<!-- PR #500: free -->

<!-- PR #501: free -->

<!-- PR #502: free -->

<!-- PR #503: free -->

<!-- PR #504: free -->

<!-- PR #505: free -->

<!-- PR #506: free -->

<!-- PR #507: free -->

<!-- PR #508: free -->

<!-- PR #509: free -->

<!-- PR #510: free -->

<!-- PR #511: free -->

<!-- PR #512: free -->

<!-- PR #513: free -->

<!-- PR #514: free -->

<!-- PR #515: free -->

<!-- PR #516: free -->

<!-- PR #517: free -->

<!-- PR #518: free -->

<!-- PR #519: free -->

<!-- PR #520: free -->

<!-- PR #521: free -->

<!-- PR #522: free -->

<!-- PR #523: free -->

<!-- PR #524: free -->

<!-- PR #525: free -->

<!-- PR #526: free -->

<!-- PR #527: free -->

<!-- PR #528: free -->

<!-- PR #529: free -->

<!-- PR #530: free -->

<!-- PR #531: free -->

<!-- PR #532: free -->

<!-- PR #533: free -->

<!-- PR #534: free -->

<!-- PR #535: free -->

<!-- PR #536: free -->

<!-- PR #537: free -->

<!-- PR #538: free -->

<!-- PR #539: free -->

<!-- PR #540: free -->

<!-- PR #541: free -->

<!-- PR #542: free -->

<!-- PR #543: free -->

<!-- PR #544: free -->

<!-- PR #545: free -->

<!-- PR #546: free -->

<!-- PR #547: free -->

<!-- PR #548: free -->

<!-- PR #549: free -->

<!-- PR #550: free -->

<!-- PR #551: free -->

<!-- PR #552: free -->

<!-- PR #553: free -->

<!-- PR #554: free -->

<!-- PR #555: free -->

<!-- PR #556: free -->

<!-- PR #557: free -->

<!-- PR #558: free -->

<!-- PR #559: free -->

<!-- PR #560: free -->

<!-- PR #561: free -->

<!-- PR #562: free -->

<!-- PR #563: free -->

<!-- PR #564: free -->

<!-- PR #565: free -->

<!-- PR #566: free -->

<!-- PR #567: free -->

<!-- PR #568: free -->

<!-- PR #569: free -->

<!-- PR #570: free -->

<!-- PR #571: free -->

<!-- PR #572: free -->

<!-- PR #573: free -->

<!-- PR #574: free -->

<!-- PR #575: free -->

<!-- PR #576: free -->

<!-- PR #577: free -->

<!-- PR #578: free -->

<!-- PR #579: free -->

<!-- PR #580: free -->

<!-- PR #581: free -->

<!-- PR #582: free -->

<!-- PR #583: free -->

<!-- PR #584: free -->

<!-- PR #585: free -->

<!-- PR #586: free -->

<!-- PR #587: free -->

<!-- PR #588: free -->

<!-- PR #589: free -->

<!-- PR #590: free -->

<!-- PR #591: free -->

<!-- PR #592: free -->

<!-- PR #593: free -->

<!-- PR #594: free -->

<!-- PR #595: free -->

<!-- PR #596: free -->

<!-- PR #597: free -->

<!-- PR #598: free -->

<!-- PR #599: free -->

<!-- PR #600: free -->

<!-- PR #601: free -->

<!-- PR #602: free -->

<!-- PR #603: free -->

<!-- PR #604: free -->

<!-- PR #605: free -->

<!-- PR #606: free -->

<!-- PR #607: free -->

<!-- PR #608: free -->

<!-- PR #609: free -->

<!-- PR #610: free -->

<!-- PR #611: free -->

<!-- PR #612: free -->

<!-- PR #613: free -->

<!-- PR #614: free -->

<!-- PR #615: free -->

<!-- PR #616: free -->

<!-- PR #617: free -->

<!-- PR #618: free -->

<!-- PR #619: free -->

<!-- PR #620: free -->

<!-- PR #621: free -->

<!-- PR #622: free -->

<!-- PR #623: free -->

<!-- PR #624: free -->

<!-- PR #625: free -->

<!-- PR #626: free -->

<!-- PR #627: free -->

<!-- PR #628: free -->

<!-- PR #629: free -->

<!-- PR #630: free -->

<!-- PR #631: free -->

<!-- PR #632: free -->

<!-- PR #633: free -->

<!-- PR #634: free -->

<!-- PR #635: free -->

<!-- PR #636: free -->

<!-- PR #637: free -->

<!-- PR #638: free -->

<!-- PR #639: free -->

<!-- PR #640: free -->

<!-- PR #641: free -->

<!-- PR #642: free -->

<!-- PR #643: free -->

<!-- PR #644: free -->

<!-- PR #645: free -->

<!-- PR #646: free -->

<!-- PR #647: free -->

<!-- PR #648: free -->

<!-- PR #649: free -->

<!-- PR #650: free -->

<!-- PR #651: free -->

<!-- PR #652: free -->

<!-- PR #653: free -->

<!-- PR #654: free -->

<!-- PR #655: free -->

<!-- PR #656: free -->

<!-- PR #657: free -->

<!-- PR #658: free -->

<!-- PR #659: free -->

<!-- PR #660: free -->

<!-- PR #661: free -->

<!-- PR #662: free -->

<!-- PR #663: free -->

<!-- PR #664: free -->

<!-- PR #665: free -->

<!-- PR #666: free -->

<!-- PR #667: free -->

<!-- PR #668: free -->

<!-- PR #669: free -->

<!-- PR #670: free -->

<!-- PR #671: free -->

<!-- PR #672: free -->

<!-- PR #673: free -->

<!-- PR #674: free -->

<!-- PR #675: free -->

<!-- PR #676: free -->

<!-- PR #677: free -->

<!-- PR #678: free -->

<!-- PR #679: free -->

<!-- PR #680: free -->

<!-- PR #681: free -->

<!-- PR #682: free -->

<!-- PR #683: free -->

<!-- PR #684: free -->

<!-- PR #685: free -->

<!-- PR #686: free -->

<!-- PR #687: free -->

<!-- PR #688: free -->

<!-- PR #689: free -->

<!-- PR #690: free -->

<!-- PR #691: free -->

<!-- PR #692: free -->

<!-- PR #693: free -->

<!-- PR #694: free -->

<!-- PR #695: free -->

<!-- PR #696: free -->

<!-- PR #697: free -->

<!-- PR #698: free -->

<!-- PR #699: free -->

<!-- PR #700: free -->

<!-- PR #701: free -->

<!-- PR #702: free -->

<!-- PR #703: free -->

<!-- PR #704: free -->

<!-- PR #705: free -->

<!-- PR #706: free -->

<!-- PR #707: free -->

<!-- PR #708: free -->

<!-- PR #709: free -->

<!-- PR #710: free -->

<!-- PR #711: free -->

<!-- PR #712: free -->

<!-- PR #713: free -->

<!-- PR #714: free -->

<!-- PR #715: free -->

<!-- PR #716: free -->

<!-- PR #717: free -->

<!-- PR #718: free -->

<!-- PR #719: free -->

<!-- PR #720: free -->

<!-- PR #721: free -->

<!-- PR #722: free -->

<!-- PR #723: free -->

<!-- PR #724: free -->

<!-- PR #725: free -->

<!-- PR #726: free -->

<!-- PR #727: free -->

<!-- PR #728: free -->

<!-- PR #729: free -->

<!-- PR #730: free -->

<!-- PR #731: free -->

<!-- PR #732: free -->

<!-- PR #733: free -->

<!-- PR #734: free -->

<!-- PR #735: free -->

<!-- PR #736: free -->

<!-- PR #737: free -->

<!-- PR #738: free -->

<!-- PR #739: free -->

<!-- PR #740: free -->

<!-- PR #741: free -->

<!-- PR #742: free -->

<!-- PR #743: free -->

<!-- PR #744: free -->

<!-- PR #745: free -->

<!-- PR #746: free -->

<!-- PR #747: free -->

<!-- PR #748: free -->

<!-- PR #749: free -->

<!-- PR #750: free -->

<!-- PR #751: free -->

<!-- PR #752: free -->

<!-- PR #753: free -->

<!-- PR #754: free -->

<!-- PR #755: free -->

<!-- PR #756: free -->

<!-- PR #757: free -->

<!-- PR #758: free -->

<!-- PR #759: free -->

<!-- PR #760: free -->

<!-- PR #761: free -->

<!-- PR #762: free -->

<!-- PR #763: free -->

<!-- PR #764: free -->

<!-- PR #765: free -->

<!-- PR #766: free -->

<!-- PR #767: free -->

<!-- PR #768: free -->

<!-- PR #769: free -->

<!-- PR #770: free -->

<!-- PR #771: free -->

<!-- PR #772: free -->

<!-- PR #773: free -->

<!-- PR #774: free -->

<!-- PR #775: free -->

<!-- PR #776: free -->

<!-- PR #777: free -->

<!-- PR #778: free -->

<!-- PR #779: free -->

<!-- PR #780: free -->

<!-- PR #781: free -->

<!-- PR #782: free -->

<!-- PR #783: free -->

<!-- PR #784: free -->

<!-- PR #785: free -->

<!-- PR #786: free -->

<!-- PR #787: free -->

<!-- PR #788: free -->

<!-- PR #789: free -->

<!-- PR #790: free -->

<!-- PR #791: free -->

<!-- PR #792: free -->

<!-- PR #793: free -->

<!-- PR #794: free -->

<!-- PR #795: free -->

<!-- PR #796: free -->

<!-- PR #797: free -->

<!-- PR #798: free -->

<!-- PR #799: free -->

<!-- PR #800: free -->

<!-- PR #801: free -->

<!-- PR #802: free -->

<!-- PR #803: free -->

<!-- PR #804: free -->

<!-- PR #805: free -->

<!-- PR #806: free -->

<!-- PR #807: free -->

<!-- PR #808: free -->

<!-- PR #809: free -->

<!-- PR #810: free -->

<!-- PR #811: free -->

<!-- PR #812: free -->

<!-- PR #813: free -->

<!-- PR #814: free -->

<!-- PR #815: free -->

<!-- PR #816: free -->

<!-- PR #817: free -->

<!-- PR #818: free -->

<!-- PR #819: free -->

<!-- PR #820: free -->

<!-- PR #821: free -->

<!-- PR #822: free -->

<!-- PR #823: free -->

<!-- PR #824: free -->

<!-- PR #825: free -->

<!-- PR #826: free -->

<!-- PR #827: free -->

<!-- PR #828: free -->

<!-- PR #829: free -->

<!-- PR #830: free -->

<!-- PR #831: free -->

<!-- PR #832: free -->

<!-- PR #833: free -->

<!-- PR #834: free -->

<!-- PR #835: free -->

<!-- PR #836: free -->

<!-- PR #837: free -->

<!-- PR #838: free -->

<!-- PR #839: free -->

<!-- PR #840: free -->

<!-- PR #841: free -->

<!-- PR #842: free -->

<!-- PR #843: free -->

<!-- PR #844: free -->

<!-- PR #845: free -->

<!-- PR #846: free -->

<!-- PR #847: free -->

<!-- PR #848: free -->

<!-- PR #849: free -->

<!-- PR #850: free -->

<!-- PR #851: free -->

<!-- PR #852: free -->

<!-- PR #853: free -->

<!-- PR #854: free -->

<!-- PR #855: free -->

<!-- PR #856: free -->

<!-- PR #857: free -->

<!-- PR #858: free -->

<!-- PR #859: free -->

<!-- PR #860: free -->

<!-- PR #861: free -->

<!-- PR #862: free -->

<!-- PR #863: free -->

<!-- PR #864: free -->

<!-- PR #865: free -->

<!-- PR #866: free -->

<!-- PR #867: free -->

<!-- PR #868: free -->

<!-- PR #869: free -->

<!-- PR #870: free -->

<!-- PR #871: free -->

<!-- PR #872: free -->

<!-- PR #873: free -->

<!-- PR #874: free -->

<!-- PR #875: free -->

<!-- PR #876: free -->

<!-- PR #877: free -->

<!-- PR #878: free -->

<!-- PR #879: free -->

<!-- PR #880: free -->

<!-- PR #881: free -->

<!-- PR #882: free -->

<!-- PR #883: free -->

<!-- PR #884: free -->

<!-- PR #885: free -->

<!-- PR #886: free -->

<!-- PR #887: free -->

<!-- PR #888: free -->

<!-- PR #889: free -->

<!-- PR #890: free -->

<!-- PR #891: free -->

<!-- PR #892: free -->

<!-- PR #893: free -->

<!-- PR #894: free -->

<!-- PR #895: free -->

<!-- PR #896: free -->

<!-- PR #897: free -->

<!-- PR #898: free -->

<!-- PR #899: free -->

<!-- PR #900: free -->

<!-- PR #901: free -->

<!-- PR #902: free -->

<!-- PR #903: free -->

<!-- PR #904: free -->

<!-- PR #905: free -->

<!-- PR #906: free -->

<!-- PR #907: free -->

<!-- PR #908: free -->

<!-- PR #909: free -->

<!-- PR #910: free -->

<!-- PR #911: free -->

<!-- PR #912: free -->

<!-- PR #913: free -->

<!-- PR #914: free -->

<!-- PR #915: free -->

<!-- PR #916: free -->

<!-- PR #917: free -->

<!-- PR #918: free -->

<!-- PR #919: free -->

<!-- PR #920: free -->

<!-- PR #921: free -->

<!-- PR #922: free -->

<!-- PR #923: free -->

<!-- PR #924: free -->

<!-- PR #925: free -->

<!-- PR #926: free -->

<!-- PR #927: free -->

<!-- PR #928: free -->

<!-- PR #929: free -->

<!-- PR #930: free -->

<!-- PR #931: free -->

<!-- PR #932: free -->

<!-- PR #933: free -->

<!-- PR #934: free -->

<!-- PR #935: free -->

<!-- PR #936: free -->

<!-- PR #937: free -->

<!-- PR #938: free -->

<!-- PR #939: free -->

<!-- PR #940: free -->

<!-- PR #941: free -->

<!-- PR #942: free -->

<!-- PR #943: free -->

<!-- PR #944: free -->

<!-- PR #945: free -->

<!-- PR #946: free -->

<!-- PR #947: free -->

<!-- PR #948: free -->

<!-- PR #949: free -->

<!-- PR #950: free -->

<!-- PR #951: free -->

<!-- PR #952: free -->

<!-- PR #953: free -->

<!-- PR #954: free -->

<!-- PR #955: free -->

<!-- PR #956: free -->

<!-- PR #957: free -->

<!-- PR #958: free -->

<!-- PR #959: free -->

<!-- PR #960: free -->

<!-- PR #961: free -->

<!-- PR #962: free -->

<!-- PR #963: free -->

<!-- PR #964: free -->

<!-- PR #965: free -->

<!-- PR #966: free -->

<!-- PR #967: free -->

<!-- PR #968: free -->

<!-- PR #969: free -->

<!-- PR #970: free -->

<!-- PR #971: free -->

<!-- PR #972: free -->

<!-- PR #973: free -->

<!-- PR #974: free -->

<!-- PR #975: free -->

<!-- PR #976: free -->

<!-- PR #977: free -->

<!-- PR #978: free -->

<!-- PR #979: free -->

<!-- PR #980: free -->

<!-- PR #981: free -->

<!-- PR #982: free -->

<!-- PR #983: free -->

<!-- PR #984: free -->

<!-- PR #985: free -->

<!-- PR #986: free -->

<!-- PR #987: free -->

<!-- PR #988: free -->

<!-- PR #989: free -->

<!-- PR #990: free -->

<!-- PR #991: free -->

<!-- PR #992: free -->

<!-- PR #993: free -->

<!-- PR #994: free -->

<!-- PR #995: free -->

<!-- PR #996: free -->

<!-- PR #997: free -->

<!-- PR #998: free -->

<!-- PR #999: free -->

<!-- PR #1000: free -->

<!-- PR #1001: free -->

<!-- PR #1002: free -->

<!-- PR #1003: free -->

<!-- PR #1004: free -->

<!-- PR #1005: free -->

<!-- PR #1006: free -->

<!-- PR #1007: free -->

<!-- PR #1008: free -->

<!-- PR #1009: free -->

<!-- PR #1010: free -->

<!-- PR #1011: free -->

<!-- PR #1012: free -->

<!-- PR #1013: free -->

<!-- PR #1014: free -->

<!-- PR #1015: free -->

<!-- PR #1016: free -->

<!-- PR #1017: free -->

<!-- PR #1018: free -->

<!-- PR #1019: free -->

<!-- PR #1020: free -->

<!-- PR #1021: free -->

<!-- PR #1022: free -->

<!-- PR #1023: free -->

<!-- PR #1024: free -->

<!-- PR #1025: free -->

<!-- PR #1026: free -->

<!-- PR #1027: free -->

<!-- PR #1028: free -->

<!-- PR #1029: free -->

<!-- PR #1030: free -->

<!-- PR #1031: free -->

<!-- PR #1032: free -->

<!-- PR #1033: free -->

<!-- PR #1034: free -->

<!-- PR #1035: free -->

<!-- PR #1036: free -->

<!-- PR #1037: free -->

<!-- PR #1038: free -->

<!-- PR #1039: free -->

<!-- PR #1040: free -->

<!-- PR #1041: free -->

