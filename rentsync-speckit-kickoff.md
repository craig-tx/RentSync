# RentSync — Spec Kit Kickoff Pack

A portfolio project for the Boom Engineering Manager application. It is a rent-payment sync and reporting pipeline for single-family rental (SFR) operators, with an overnight AI agent that triages exceptions.

**What it shows:** a Ruby (Grape + Sequel) backend; a Next.js/TypeScript front end; OAuth 2.0; webhooks; idempotency; handling rate limits; observability; AWS/Terraform; and autonomous Claude Code development guided by specs.

---

## 0. Setup (terminal)

```bash
# Install the Spec Kit CLI (needs uv)
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git

mkdir rentsync && cd rentsync
git init
specify init . --ai claude      # newer versions may use: --integration claude  (check: specify init --help)
specify check
```

Then open Claude Code in `rentsync/`. Spec Kit registers the `/speckit.*` commands. The flow for each feature is:

`/speckit.specify` → `/speckit.clarify` → `/speckit.plan` → `/speckit.tasks` → `/speckit.analyze` → `/speckit.implement`

Each `/speckit.specify` creates a numbered feature branch (for example, `001-mock-pms`). Merge each feature before you start the next one.

---

## 1. Constitution (run once)

Paste this:

```
/speckit.constitution Create principles for RentSync, a portfolio-grade rent payment sync and reporting service for single-family rental operators. Principles:

1. Correctness over cleverness: financial data must never be double-counted, silently dropped, or mutated without an audit trail. Every ledger change is append-only with a recorded reason and actor (system, user, or agent).
2. Idempotency everywhere: every inbound event and every outbound side effect is safe to retry. Idempotency keys are explicit and documented.
3. Test-first for domain logic: ledger matching, idempotency, and export formatting have unit tests written before implementation. Integration tests cover webhook ingestion end to end. CI must be green before merge.
4. Integrations are hostile by default: assume duplicate, out-of-order, delayed, malformed, and rate-limited traffic. Design for it explicitly.
5. AI agents propose, humans dispose: agents never write to the ledger directly. They create proposals that a human approves or rejects in the UI. All agent actions are logged and evaluated.
6. Observable by default: structured JSON logs with correlation IDs, request/job metrics, and a health endpoint on every service.
7. Secure by default: verify webhook HMAC signatures, encrypt OAuth tokens at rest, keep secrets out of the repo, and treat PII (tenant names, amounts) as sensitive in logs.
8. Simplicity: prefer boring, well-understood libraries. No new dependency without a one-line justification in the plan.
9. Documented decisions: significant tradeoffs get a short ADR in docs/adr/.
```

---

## 2. Feature roadmap

Run these in order. Each block is one Spec Kit cycle. Keep `/speckit.specify` focused on **what and why**. The tech stack goes in `/speckit.plan` (section 3).

### 001 — Mock property-management system (PMS)

```
/speckit.specify Build a simulated property management system (PMS) that stands in for real platforms like the ones SFR operators use. It must:
- Act as an OAuth 2.0 authorization server (authorization code flow with refresh tokens; access tokens expire quickly so refresh logic is exercised).
- Hold seed data: ~3 operators, ~50 properties, ~60 tenants and leases, and 12 months of rent charges and payments, including partial payments, late payments, NSF reversals, and a few tenants who move out mid-lease.
- Expose a REST API for properties, leases, tenants, charges, and payments, with pagination and per-client rate limits that return 429 with Retry-After.
- Send signed webhooks (HMAC) for payment.created, payment.reversed, lease.updated, and tenant.moved_out to a registered subscriber URL.
- Include configurable "chaos" settings: duplicate delivery rate, out-of-order delivery, delayed delivery, occasional 500s, and malformed payloads, so the consumer's resilience can be demonstrated.
- Provide a small admin endpoint to replay events and to trigger a scenario (for example, "simulate month-end payment burst").
This is a test harness, not a product: keep it small, but realistic.
```

### 002 — Connection and webhook ingestion

```
/speckit.specify Build the RentSync integration layer. An operator connects their PMS account through OAuth; RentSync stores the tokens securely and refreshes them automatically. RentSync receives PMS webhooks, verifies their signatures, and records each raw event exactly once even when it is delivered multiple times or out of order. A periodic reconciliation job pulls payments through the PMS API (respecting rate limits and backing off on 429s) to catch anything webhooks missed. Operators can see connection health: last successful sync, token status, events received, events rejected, and why.
```

### 003 — Tenant payment ledger and matching

```
/speckit.specify Build the tenant payment ledger. Raw PMS events become a normalized, append-only ledger per lease: charges, payments, partial payments, reversals, and adjustments. Payments are matched to the charges they satisfy, so each month for each lease has a clear status: paid on time, paid late (with days late), partially paid, unpaid, or reversed. Anything the system cannot confidently match or explain becomes an "exception" with a reason code (for example: payment with no open charge, amount mismatch, reversal without original, duplicate suspected). The ledger must be fully explainable: for any balance, a user can trace back to the raw events that produced it.
```

### 004 — Operator dashboard

```
/speckit.specify Build a web dashboard for property operators. Views: portfolio summary (on-time rate, delinquency, open exceptions), a tenant list with a 12-month payment-history strip for each lease, a lease detail page showing the ledger with drill-down to source events, an exceptions queue, and a connection-health page. Operators sign in, and each operator sees only their own data.
```

### 005 — Monthly credit-reporting export

```
/speckit.specify Build a monthly rent-reporting export. For a chosen month, generate a file describing each tenant's payment status in a format inspired by the credit bureau Metro 2 standard (clearly labeled as a simplified, non-compliant demo format). Leases with unresolved exceptions are held back and listed separately with the reasons. Only tenants who have opted in are included. Exports are versioned and reproducible: regenerating the same month with the same data produces an identical file, and every export records what data it was built from.
```

### 006 — Overnight exception-triage agent

```
/speckit.specify Build an AI exception-triage agent that runs on a nightly schedule. For each open ledger exception, it investigates using read-only tools (ledger lookups, raw event lookups, PMS API reads) and produces a proposal: a suggested resolution (match payment X to charge Y, flag as duplicate, mark reversal against original Z, or escalate to a human), a confidence level, and a plain-English rationale citing the evidence. Proposals appear in the dashboard's review queue, where an operator approves or rejects each one. Approved proposals apply to the ledger with the agent and approver recorded. The agent must never change the ledger itself, must never invent evidence, and must escalate when unsure. Include an evaluation suite: a fixed set of realistic exception scenarios with expected outcomes, run in CI, reporting accuracy, escalation rate, and any unsafe actions attempted.
```

### 007 — Infrastructure and delivery

```
/speckit.specify Make RentSync deployable and operable. Local development runs entirely through Docker Compose (API, workers, mock PMS, database, cache, web). A cloud deployment to AWS is defined in Terraform (database, container services, secrets, logging) and can be validated with a plan without actually being applied. CI runs linting, type checks, unit and integration tests, and the agent evals on every pull request. Include a short runbook covering how to replay failed webhooks, rotate a PMS connection, and investigate a ledger discrepancy.
```

---

## 3. Plan prompt (the tech stack, reused for each feature)

Run `/speckit.plan` with this text, plus any notes specific to the feature:

```
/speckit.plan Tech stack and constraints:
- Backend API: Ruby 3.3+, Grape (mounted on Rack/Puma), Sequel ORM with PostgreSQL 16. No Rails.
- Background jobs: Sidekiq with Redis for webhook processing, reconciliation, exports, and the nightly agent.
- Mock PMS: a separate small Ruby service (Grape or Sinatra) in /mock_pms with its own database schema.
- Frontend: Next.js (App Router) + TypeScript (strict), Tailwind, TanStack Query; typed API client generated from or kept in sync with the backend's OpenAPI description.
- OAuth: authorization code + refresh tokens; tokens encrypted at rest.
- Webhooks: HMAC-SHA256 signature verification; raw events persisted with a unique (source, event_id) constraint for idempotency; processing is asynchronous and retry-safe.
- Rate limits: client-side token bucket plus exponential backoff with jitter, honoring Retry-After.
- AI agent: the Anthropic API (Claude) with tool use and structured output; tools are read-only; proposals are stored in a table and require human approval.
- Testing: RSpec + Rack::Test for the backend, Vitest + Playwright for the frontend, and an agent eval harness under /evals with recorded fixtures.
- Observability: structured JSON logs with correlation IDs that carry from the webhook through the job to the ledger entry; Prometheus-style metrics endpoint; /healthz.
- Infra: Docker Compose locally; Terraform for AWS (RDS Postgres, ECS Fargate, ElastiCache, Secrets Manager, CloudWatch). Terraform must validate and plan; applying is optional.
- CI: GitHub Actions.
- Repo layout: /api, /mock_pms, /web, /evals, /infra, /docs (adr/, design.md, runbook.md, ai-build-log.md).
Record notable tradeoffs as ADRs.
```

After `/speckit.tasks`, run `/speckit.analyze` before `/speckit.implement` so it catches gaps between the spec, the plan, and the tasks.

---

## 4. Add this to CLAUDE.md

```markdown
## Project: RentSync
Portfolio project demonstrating integration engineering in Ruby (Grape/Sequel) + Next.js/TypeScript.
Workflow: GitHub Spec Kit. Specs live in /specs; the constitution in .specify/memory/constitution.md is authoritative.

## Working rules
- Follow the current feature's tasks.md in order; tick tasks off as you complete them.
- Write failing tests before domain logic (ledger, matching, idempotency, export).
- Never weaken a test to make it pass. If a test seems wrong, stop and note it in docs/ai-build-log.md.
- Run the full test suite before each commit; commit in small, well-described steps.
- No new dependencies without a justification line in plan.md.
- Never commit secrets; use .env.example.
- At the end of each session, append to docs/ai-build-log.md: what was done, what was blocked, decisions made, and the next task.
```

---

## 5. Running it overnight

1. Before bed: finish `/speckit.tasks` and `/speckit.analyze` for one feature, then start `/speckit.implement` in an unattended session. Use a container or a separate branch, and grant only the permissions the session needs. Check the Claude Code docs for the current headless and permission-mode options.
2. Use the test suite as the guardrail. A task is done only when its tests pass.
3. In the morning: read `docs/ai-build-log.md`, review the diff, fix course, and merge.
4. Keep notes on what worked and what didn't. They become the "How I built this with AI" section of the README, which is the main thing the hiring team will want to discuss.

---

## 6. Finish line (what the repo should show)

- [ ] A README with a 2-minute overview, an architecture diagram, `docker compose up` quick start, and a "How I built this with AI" section
- [ ] `docs/design.md`: one page covering idempotency keys, ordering, reconciliation, and the agent's safety boundary
- [ ] 3–5 ADRs
- [ ] A chaos demo: crank up duplicate and out-of-order delivery and show that the ledger stays correct
- [ ] Agent eval results in CI, with accuracy and escalation rate
- [ ] `terraform plan` succeeding in CI
- [ ] `docs/ai-build-log.md` showing real autonomous sessions
