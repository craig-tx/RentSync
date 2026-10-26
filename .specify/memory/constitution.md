<!--
Sync Impact Report (remove before merge)
- Version: 1.6.0 → 1.7.0 (MINOR: new Development Workflow rule)
- Added: Development Workflow & Quality Gates → "Cross-platform development" (Windows and macOS
  developer machines; portable bash, Ruby or Docker for scripts; side-by-side instructions;
  line endings and modes fixed in the repo)
- Modified principles: none. Removed sections: none.
- Templates: none need changes (they read the constitution at runtime).
- Follow-up: infra/bootstrap/test/bootstrap_iam_test.sh line 106 uses GNU `sed -i` with no
  suffix, which fails on macOS sed. Fix in a separate change.
-->
# RentSync Constitution

## Core Principles

### I. Correctness Over Cleverness

Financial data MUST NOT be double-counted, silently dropped, or mutated without an audit trail.

- The ledger is append-only. Corrections are new entries such as reversals or adjustments;
  existing entries MUST NOT be updated in place or deleted.
- Every ledger entry MUST record a reason, the actor that caused it (`system` or `user`), and
  the source it came from (raw event IDs, an approved proposal, or a user action).
- When an approved agent proposal is applied, the entry MUST record both the proposing agent
  and the approving human. The agent is never the writing actor (see Principle V).
- Every balance and monthly status MUST be traceable back to the raw events that produced it.
- When the system cannot confidently match or explain a record, it MUST raise an exception
  with a reason code. It MUST NOT guess.

**Rationale**: Rent data feeds delinquency decisions and credit reporting. One silent error
costs trust that cleverness never earns back.

### II. Idempotency Everywhere

Every inbound event and every outbound side effect MUST be safe to retry.

- Inbound events MUST be deduplicated on an explicit, documented key (for example
  `(source, event_id)`), enforced by a database uniqueness constraint, not only by code.
- Outbound side effects (API calls, ledger applications, exports, notifications) MUST carry an
  idempotency key or be naturally idempotent. Retrying one MUST NOT create a second effect.
- Each feature's plan MUST document its idempotency keys and what each one protects.
- Running a job twice with the same inputs MUST produce the same end state.

**Rationale**: Retries and duplicate deliveries are normal. Correctness under retry has to be
built into the design, because it cannot be bolted on later.

### III. Test-First for Domain Logic (NON-NEGOTIABLE)

- Ledger, matching, idempotency, and export-formatting logic MUST have unit tests that are
  written and seen to fail before the implementation exists.
- Webhook ingestion MUST have an end-to-end integration test that runs from the signed HTTP
  request to the persisted ledger effect.
- A test MUST NOT be weakened, skipped, or deleted to make it pass. If a test looks wrong,
  work stops on it and the issue is logged in `docs/ai-build-log.md` for human review.
- CI MUST be green before any merge.

**Rationale**: In an autonomous, spec-driven build, the test suite is the guardrail. A task is
done only when its tests pass.

### IV. Integrations Are Hostile by Default

Every external integration MUST be designed for traffic that is duplicated, out of order,
delayed, malformed, and rate-limited.

- Ordering MUST NOT be assumed. Processing MUST tolerate late and out-of-order events, and the
  plan MUST say how each case resolves.
- Malformed or unverifiable input MUST be rejected and recorded with a reason. It MUST NOT be
  dropped silently.
- Clients MUST honor rate limits: `429` with `Retry-After` is respected, with exponential
  backoff and jitter on retries.
- Webhooks are not the only source of truth. A reconciliation path MUST exist to catch what
  webhooks miss.
- Each of these behaviors MUST be covered by a test or the mock PMS chaos settings.

**Rationale**: Real property-management platforms behave this way. Demonstrating resilience to
it is the point of this project.

### V. AI Agents Propose, Humans Dispose (NON-NEGOTIABLE)

- Agents MUST NOT write to the ledger or change any financial state directly. Agent tools MUST
  be read-only.
- Agent output MUST be a stored proposal containing a suggested resolution, a confidence level,
  and a rationale that cites real evidence. An agent MUST NOT invent evidence.
- When an agent is unsure, it MUST escalate to a human instead of guessing.
- A proposal reaches the ledger only after a human approves it. The system then applies it,
  recording both the agent and the approver.
- Every agent run, tool call, and proposal MUST be logged.
- Agent behavior MUST be evaluated in CI against a fixed scenario suite that reports accuracy,
  escalation rate, and any unsafe actions attempted. An unsafe action attempted in evals fails
  the build.

**Rationale**: An autonomous agent on financial data is only acceptable behind a hard,
auditable safety boundary.

### VI. Observable by Default

- Every service MUST emit structured JSON logs with a correlation ID. The ID MUST carry through
  from the webhook to the job to the ledger entry.
- Every service MUST expose request and job metrics and a health endpoint (`/healthz`).
- Rejected events, retries, and exceptions MUST be visible as metrics or log events.
- **Logs and metrics from every service MUST be delivered over OTLP (the OpenTelemetry
  Protocol) to a single OTLP-compatible backend**, such as OpenObserve.
  - The service MAY send OTLP itself, or an OpenTelemetry Collector MAY collect the service's
    standard output (JSON logs on stdout, a metrics endpoint) and forward it as OTLP. Each
    plan chooses which.
  - The backend and its endpoint MUST be configuration only, using the standard `OTEL_*`
    environment variables or the Collector's config. Application code MUST NOT call a
    vendor-specific telemetry API, so changing the backend never requires a code change.
  - All telemetry MUST carry the resource attributes `service.name`, `service.version`,
    `deployment.environment`, and `deployment.id` (the DeploymentId, below). Instance-level
    data MUST also carry `service.instance.id`.
- Exporting telemetry MUST NOT block a request or a job, and MUST NOT make one fail.
  - Export runs asynchronously from bounded buffers (Principle X).
  - If the backend is unreachable, telemetry is dropped, and the number dropped is itself
    counted.
  - The service keeps writing logs to stdout as a fallback.
- Telemetry that leaves a process is subject to Principle VII. Secrets and unredacted personal
  data MUST be removed before export, not at the backend.
- Local development and CI MUST run an OTLP backend (or Collector plus backend), so that every
  feature's telemetry can be seen and checked end to end.

**DeploymentId.** Every standalone deployment of the set of services MUST have a
DeploymentId.

- **What it identifies**: one long-lived stack instance, for example `prod-us` (production),
  `dev-staging` (staging), or `local-<name>` (a developer machine). It does not identify a
  release. The build that is running stays `service.version`.
- **Format**: 3 to 16 characters of lowercase letters, digits, and hyphens. It starts with a
  letter and does not end with a hyphen (`^[a-z][a-z0-9-]{1,14}[a-z0-9]$`). Infrastructure code
  MUST validate it.
- **Telemetry**: all logs and metrics MUST carry it as the `deployment.id` resource attribute.
- **Resource names**: it MUST be a component of the identifier of every resource the deployment
  owns. This includes cloud resource names, IAM roles, parameter and secret paths, container
  registry paths where they are per-deployment, and database names. Where a naming scheme
  forbids hyphens, as unquoted Postgres identifiers do, hyphens become underscores
  (`mock_pms_prod_us`).
- **Tags**: every cloud resource MUST carry a `DeploymentId` tag with its value. Infrastructure
  code MUST apply the tag by default, through provider-level default tags, rather than one
  resource at a time.
- **Shared resources**: a resource that several deployments use, such as a shared telemetry
  backend, belongs to a deployment of its own and carries that deployment's DeploymentId.
- **Never hard-coded**: no name, path, address, or identifier owned by a deployment may be
  hard-coded. Each one MUST be derived from the DeploymentId or supplied as that deployment's
  configuration.

These rules let any number of deployments run **side by side in the same cloud account**, for
example a short-lived `pr-42` next to `dev-staging` and `prod-us`. Their names, paths, and
databases never collide. Each deployment's resources, cost, and telemetry can be found and
attributed by one value. A deployment can be torn down completely by selecting everything that
carries its tag.

**Rationale**: Diagnosing a ledger discrepancy means being able to follow one event across
every service it touched. Delivering logs and metrics to one place over an open protocol makes
that possible, without tying the code to any one vendor. Tying every log line, metric, and
resource to one DeploymentId makes "which stack did this come from, and what does it cost?" a
single filter, and lets new deployments be added without editing the old ones.

### VII. Secure by Default

- Inbound webhooks MUST have their HMAC signatures verified before any processing. Requests
  that fail verification are rejected and recorded.
- OAuth access and refresh tokens MUST be protected at rest. A system that must present a
  token again later, such as RentSync calling a PMS, MUST encrypt it. A system that only verifies
  tokens it issued, such as the mock PMS authorization server, MUST store only a one-way hash and
  never the token itself.
- Secrets MUST NOT be committed. Configuration is documented in `.env.example`.
- Tenant PII (names, contact details, payment amounts) is sensitive. It MUST NOT appear
  unredacted in logs, metrics, or error messages.
- Each operator MUST see only their own data. Authorization MUST be enforced on the server.

**Rationale**: This project handles tenants' financial data. Security is a baseline, not a
feature.

### VIII. Simplicity

- Prefer boring, well-understood libraries and patterns.
- A new dependency MUST have a one-line justification in that feature's `plan.md`. The
  justification MUST say why writing it locally isn't reasonable.
- **Avoid trivial dependencies.** When deciding whether to take a dependency, lean toward not
  taking it if the functionality can reasonably be written and tested locally. Try, in order:
  1. the language's standard library;
  2. a small local implementation, with its own tests;
  3. a dependency.

  A dependency is the right choice when the problem is genuinely hard, large or
  security-sensitive: for example cryptography, password hashing, TLS, database drivers, or
  parsers for protocols and file formats. The package must also be widely used and actively
  maintained. Cryptographic primitives MUST never be written locally.
- Build only what the current spec requires. Any extra complexity MUST be justified in the
  plan's Complexity Tracking table.

**Rationale**: Every dependency and abstraction is a maintenance cost. A small, legible system
is easier to verify and to explain. A package that does something trivial, such as padding or
trimming a string, saves minutes once. It costs supply-chain risk, update churn (Development
Workflow, "Dependency maintenance") and breakage outside the project's control for as long as
it stays. The 2016 npm `left-pad` incident broke thousands of builds over an 11-line function.

### IX. Documented Decisions

- A significant tradeoff MUST be recorded as a short ADR in `docs/adr/`. This covers anything
  that affects data integrity, security, the agent safety boundary, or service boundaries, or
  that would be costly to reverse.
- An ADR MUST state its context, the decision, the alternatives considered, and the
  consequences.

**Rationale**: Decisions that are written down can be reviewed, revisited, and explained.

### X. Stateless, Horizontally Scalable Services

Every design decision MUST keep service processes stateless, so that any service can scale out
by adding instances.

- A process MUST NOT keep anything in memory that has to be shared across requests or
  instances, or that has to survive a restart. That includes sessions, rate-limit buckets,
  counters and metrics, locks, queues, and caches that must stay coherent across instances.
  Such state belongs in a shared external store: Postgres for durable data, Redis for
  short-lived data.
- Correctness MUST NOT depend on how many instances are running or which instance handles a
  request. Any instance MUST be safe to stop at any time without losing committed data.
- Background work MUST be coordinated through the shared store, for example with
  `SKIP LOCKED` claims or leases. It MUST NOT rely on a process-local scheduler that assumes it
  is the only instance. If a job genuinely needs a single runner, it MUST hold a lease or lock
  in the shared store.
- Process memory MAY hold:
  - data for a single request,
  - immutable configuration,
  - buffers and caches that can be lost safely and are reconciled to the shared store, such as
    metric deltas flushed periodically.

  Each plan MUST state how much data a buffer can lose if the process crashes.
- Shared state MUST be updated with atomic operations (conditional `UPDATE`, unique
  constraints, Redis atomic commands, or Lua scripts) rather than read-modify-write sequences.
  Distributed locks are a last resort, and a plan that uses one MUST justify it.
- Any exception to this principle MUST be justified in the plan's Complexity Tracking table.

**Rationale**: A stateless service can be scaled, restarted, and replaced without coordination.
State held inside one process is a hidden single point of failure, and it breaks silently when
a second instance starts.

## Scope & Data Constraints

- RentSync is a portfolio-grade demonstration. It MUST NOT be presented as production-ready or
  regulatory-compliant.
- The mock PMS is a test harness, not a product. It stays small but realistic, and it MUST
  support the chaos behaviors Principle IV needs.
- The credit-reporting export is inspired by Metro 2. It MUST be clearly labeled as a
  simplified, non-compliant demo format.
- The export MUST include only tenants who have opted in, and MUST hold back leases with
  unresolved exceptions.
- Exports MUST be versioned and reproducible: the same month built from the same data produces
  a byte-identical file and records the data it was built from.
- Seed and fixture data MUST be synthetic. Real tenant data MUST NOT enter the repository.
- Stack and tooling choices belong in each feature's `plan.md`, not in this constitution. A plan
  MUST NOT contradict these principles.

## Development Workflow & Quality Gates

- Every feature follows the Spec Kit flow: specify → clarify → plan → tasks → analyze →
  implement. `/speckit-analyze` MUST run before `/speckit-implement`.
- Each feature is built on its own numbered branch and merged before the next feature starts.
- Every `plan.md` MUST pass its Constitution Check gate before design work begins, and again
  after design. Violations MUST be justified in Complexity Tracking or the plan is revised.
- Tasks are done in `tasks.md` order and ticked off as they are completed. A task is done only
  when its tests pass.
- The full test suite MUST pass before each commit. Commits are small and clearly described.
- CI (lint, type checks, unit and integration tests, agent evals) MUST be green before merge.
- At the end of each autonomous or interactive build session, an entry MUST be appended to
  `docs/ai-build-log.md`: what was done, what was blocked, decisions made, and the next task.
- Unattended sessions run on a separate branch or in a container, with only the permissions
  the session needs. Their output is reviewed by a human before merge.
- **Explicit system names**: every reference to an account or its identifier MUST name the
  system it belongs to, for example "AWS account ID", "HCP Terraform organization", "GitHub
  account", or "NameCheap account". A bare "account" is not allowed.
  - This applies everywhere the project controls the wording: documentation, CLI flags and
    switches, placeholders, comments, variable and parameter names, configuration keys, log and
    error messages, and task and spec text. Examples: `--aws-account`, not `--account`;
    `<aws-account-id>`, not `<account>`; `aws_account_id`, not `account`.
  - The only exception is a name the project does not control, such as the `Account` field
    returned by `aws sts get-caller-identity`. Where such a name is used, the surrounding text
    or variable name MUST still say which system it belongs to.
  - **Rationale**: the project spans several systems that each have accounts (AWS, HCP
    Terraform, GitHub, NameCheap, OpenObserve). An operator who has to guess which one a value
    belongs to can enter it in the wrong place, and in a bootstrap step that mistake can grant
    access to the wrong system.
- **Reversible bootstrap**: everything the bootstrap provisions MUST be removable by a teardown
  command. This covers cloud identities and roles, HCP Terraform projects, variable sets and
  workspaces, GitHub variables and Environments, and anything a future bootstrap step adds.
  - Every bootstrap step MUST ship with its teardown, in the same change, tested the same way.
  - The teardown MUST first list exactly what it will delete. It MUST then warn plainly that
    everything listed will be permanently deleted, and ask the operator a simple arithmetic
    question. Nothing is deleted unless the answer is correct; a wrong or missing answer, or no
    interactive terminal, deletes nothing.
  - The teardown MUST refuse while infrastructure still depends on what it would delete, for
    example a workspace that still manages resources. Infrastructure is destroyed first, through
    its own documented procedure, so nothing is left running without the identities that manage
    it.
  - The teardown removes only what the bootstrap created. Anything it adopted, such as an OIDC
    provider that already existed, is left in place and reported. Security protections the
    bootstrap turned on, such as secret scanning, are also left on and reported.
  - **Rationale**: the bootstrap evolves, and the operator must be able to return to a blank
    slate and prove the current bootstrap works from scratch. A deliberate confirmation step
    keeps that power from being used by accident.
- **Dependency maintenance**: maintainers MUST keep every dependency current on a fixed
  schedule. Automation such as Dependabot helps but is optional; the schedule is not.
  - **Scope:** the Ruby version and gems; container base images and service images (for
    example Postgres, Redis, Caddy, OpenObserve and the OpenTelemetry Collector); GitHub
    Actions; the Terraform CLI and providers; and the host operating system image (AMI).
  - **At least monthly:** review every pending update and merge or decline it, recording why
    when declined. Patch the host AMI in the same pass.
  - **Security advisories rated high or critical:** address within 7 days, by updating,
    mitigating, or recording why the advisory does not apply.
  - **At least quarterly:** review every component that has a newer major version or is
    approaching end-of-life. For each one, either plan the port as a tracked task or issue,
    or record why not yet. A component MUST NOT run past its end-of-life without a recorded
    decision.
  - Updates go through the normal pull request and CI gates. A test MUST NOT be weakened to
    accept an update (Principle III).
  - Each review is recorded in `docs/ai-build-log.md`: what was updated, what was declined
    and why, and which major-version ports are planned.
  - **Rationale**: dependencies age whether or not anyone looks at them. Unpatched components
    are a leading source of vulnerabilities, and a major-version jump deferred too long
    becomes a rewrite. A fixed schedule keeps updates small, reviewed and routine.
- **Cross-platform development**: a developer MUST be able to build, test, run and operate the
  project from either Windows or macOS. No contributor or operator is required to change
  platforms.
  - **Scope:** every developer-facing script, tool requirement and instruction. That includes
    the runbook, quickstart, README, bootstrap scripts, test commands and local Docker stack.
  - **Scripts** are written in portable bash (4.4 or later, which Git Bash and WSL provide on
    Windows and Homebrew provides on macOS), in Ruby, or run inside Docker. A script MUST NOT
    depend on a shell or tool that exists on only one of the two, for example PowerShell, zsh,
    or GNU-only flags of `sed`, `date` or `grep`, unless it also works with the other
    platform's version.
  - **Instructions:** where a step differs between Windows and macOS, both versions are
    documented side by side, at the same level of detail. A tool requirement names how to
    install it on each platform.
  - **Files:** line endings and executable bits are fixed in the repository, through
    `.gitattributes` and git file modes, so a checkout on either platform runs the same
    way. Paths in scripts and docs use forward slashes, and file names never differ only by
    letter case.
  - Linux is supported as a matter of course, because CI and the servers run it, but Windows
    and macOS are the explicit commitment for developer machines.
  - **Rationale**: no one should be forced onto a platform that does not suit them. WSL, Git
    Bash, Homebrew and Docker make supporting both practical, so the cost is mostly care
    when writing scripts and docs. A project that works only on its author's platform also
    shuts out reviewers and future maintainers who use the other one.

## Governance

- This constitution supersedes all other project practices and guidance. Runtime development
  guidance lives in `CLAUDE.md` and MUST NOT contradict this document.
- **Amendments**: changes are made through a pull request that edits
  `.specify/memory/constitution.md` with a Sync Impact Report that a human reviews and that is
  removed before merge. The PR also updates the version and Last Amended date, and records the
  rationale for any change that alters a principle.
- **Versioning**: semantic versioning.
  - MAJOR: a principle is removed or redefined in a backward-incompatible way.
  - MINOR: a principle or section is added, or guidance is materially expanded.
  - PATCH: clarifications, wording, or typo fixes.
- **Compliance review**: every plan's Constitution Check, every `/speckit-analyze` run, and
  every PR review MUST verify compliance with these principles. Any unjustified violation
  blocks the merge.

**Version**: 1.7.0 | **Ratified**: 2026-10-20 | **Last Amended**: 2026-10-26
