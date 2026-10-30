# ADR-0009: Background work claimed from Postgres, not Sidekiq

- **Status:** Accepted
- **Date:** 2026-10-29
- **Feature:** 003-pms-ingestion (research R2, R5)

## Context

RentSync's background work in feature 003 consists of three jobs:
- reconciling each connection every 15 minutes, or at once when the operator asks;
- renewing access tokens before those calls;
- a daily purge of short-lived rows.

Webhooks are recorded inside the request, because the PMS may only get a success once the
event is durable (FR-011). So no events are queued.

The plan's kickoff named Sidekiq and Redis. Constitution VIII asks for a justification for every
dependency, and X asks for stateless services that are correct at any instance count. The
hosts are t4g.micro with 1 GiB of memory (research R14).

## Decision

One `api_worker` loop (`bin/worker`) runs registered jobs. Each job claims its own work from
Postgres:

- **Reconciliation:** the scheduler claims one due connection with `UPDATE pms_connections SET
  reconcile_lease_until = now + 300 s WHERE id IN (SELECT … WHERE status IN (live) AND
  next_reconcile_at <= now AND lease expired FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING …`.
  The run extends the lease after each page, saves its cursor with the page's facts, and
  clears the lease when it ends. A killed worker's lease lapses. The next claimant marks the
  open run `failed / interrupted` and resumes from the cursor.
- **Reconcile now:** sets `next_reconcile_at = now` and `reconcile_requested_at`, so the
  run is named `manual`. A press during a run makes the next run due at once.
- **Daily purge:** an upsert on a `maintenance_leases` row that succeeds only when the last run
  is a day old and nobody holds the lease.
- **Token renewal:** a conditional `UPDATE` on `renewal_lease_until`, done by whichever caller
  needs the token. It is not a job of its own.

## Alternatives considered

- **Sidekiq plus `sidekiq-cron`.** Two gems and a process for three periodic jobs, and a
  periodic scheduler is a paid Sidekiq feature or another gem. Its retries would duplicate the
  backoff the runs already keep in Postgres.
- **Recording webhooks through a queue.** Acknowledging before the event is durable breaks
  FR-011.
- **A Redis lock per connection.** It adds a second place where claim state lives, and the
  lease would not commit together with the cursor and the facts.

## Consequences

- No new dependency and no extra memory. Any number of workers is safe; scheduler_spec checks
  that two at once never claim the same connection.
- Claims cost a small indexed query each worker tick, which is trivial at demo scale (a
  handful of connections).
- A run longer than its lease without a page in between could be claimed twice. Pages arrive
  every few seconds and the lease is 300 s, so this needs a stall longer than five minutes.
  The second claimant then closes the first run as interrupted.
- **Revisit when** the ledger (the next feature) needs high-volume asynchronous jobs, such as
  processing every raw event. That is a job queue, and Sidekiq or a Postgres-backed queue such
  as `good_job` should be weighed then, against this ADR.
