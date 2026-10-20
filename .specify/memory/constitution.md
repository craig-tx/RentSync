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

**Rationale**: Diagnosing a ledger discrepancy means being able to follow one event across
every service it touched.

### VII. Secure by Default

- Inbound webhooks MUST have their HMAC signatures verified before any processing. Requests
  that fail verification are rejected and recorded.
- OAuth access and refresh tokens MUST be encrypted at rest.
- Secrets MUST NOT be committed. Configuration is documented in `.env.example`.
- Tenant PII (names, contact details, payment amounts) is sensitive. It MUST NOT appear
  unredacted in logs, metrics, or error messages.
- Each operator MUST see only their own data. Authorization MUST be enforced on the server.

**Rationale**: This project handles tenants' financial data. Security is a baseline, not a
feature.

### VIII. Simplicity

- Prefer boring, well-understood libraries and patterns.
- A new dependency MUST have a one-line justification in that feature's `plan.md`.
- Build only what the current spec requires. Any extra complexity MUST be justified in the
  plan's Complexity Tracking table.

**Rationale**: Every dependency and abstraction is a maintenance cost. A small, legible system
is easier to verify and to explain.

### IX. Documented Decisions

- A significant tradeoff MUST be recorded as a short ADR in `docs/adr/`. This covers anything
  that affects data integrity, security, the agent safety boundary, or service boundaries, or
  that would be costly to reverse.
- An ADR MUST state its context, the decision, the alternatives considered, and the
  consequences.

**Rationale**: Decisions that are written down can be reviewed, revisited, and explained.

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

**Version**: 1.0.0 | **Ratified**: 2026-10-20 | **Last Amended**: 2026-10-20
