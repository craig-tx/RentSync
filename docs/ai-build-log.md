# AI Build Log

The constitution's Development Workflow section requires an entry at the end of every build session, whether autonomous or interactive.

## Entry template

```
### YYYY-MM-DD — <session type: interactive | unattended>
- **Done:**
- **Blocked:**
- **Decisions:**
- **Next task:**
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
