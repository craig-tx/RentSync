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
