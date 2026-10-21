# ADR-0001: Transactional outbox in Postgres for mock webhook delivery

- **Status:** Accepted
- **Date:** 2026-10-20
- **Feature:** 001-mock-pms (research R6, R7)

## Context

The mock PMS sends signed webhooks for four event types to every subscribed client.

- Deliveries must survive restarts and be retried with backoff.
- Every attempt goes into an inspectable log (FR-020).
- Replays must be possible, keeping the original event ID (FR-029).
- Chaos needs exact control over when each delivery is sent: duplicates, reordering, delays (FR-023).
- Every effect must be measurable afterwards (SC-005), and a given seed must reproduce the same chaos decisions (FR-026).

## Decision

Use a **transactional outbox in Postgres**:

- A business change, its immutable `events` row, and one `deliveries` row per subscribed client with an active grant are all written **in one transaction**.
- A separate worker process (`bin/delivery_worker`):
  - polls every second;
  - claims due deliveries with `FOR UPDATE SKIP LOCKED`;
  - sends each one with the stdlib `Net::HTTP`;
  - writes an immutable `delivery_attempts` row;
  - then marks the delivery succeeded, reschedules it (`RETRY_BASE_SECONDS × 2^(n−1)`, ±10%), or marks it exhausted after `MAX_ATTEMPTS`.
- A reaper puts deliveries left `in_flight` for more than 60 s back to `pending`.
- Chaos is decided when a delivery is created and stored on the row. The worker only carries it out.

## Alternatives considered

- **Sidekiq and Redis**, as the main backend uses. Scheduled-job sets are harder to inspect for chaos verification than table rows, and an event and its deliveries could not be committed atomically with the business change.
- **An in-process thread pool.** It loses deliveries on restart, leaves the delivery log incomplete, and ties delivery to a single process (Constitution X).

## Consequences

- **Delivery is at-least-once.** A worker crash after sending but before recording the attempt causes a retry. Subscribers **must** deduplicate on `PMS-Event-Id`, which is exactly what feature 002 is built to demonstrate.
- Any number of workers can run safely, because claims are row-level and use `SKIP LOCKED`.
- Delays and reordering are just a `scheduled_at` value, and a replay is just a new `deliveries` row for an existing event.
- Postgres carries the polling load. At harness volumes (dozens of events per minute) that is negligible.
