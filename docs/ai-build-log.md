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
