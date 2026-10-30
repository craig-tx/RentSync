# ADR-0011: Exactly-once raw events from at-least-once webhooks

- **Status:** Accepted
- **Date:** 2026-10-29
- **Feature:** 003-pms-ingestion (research R3, R4, R10)

## Context

The PMS delivers webhooks at least once. Chaos adds duplicates, reordering, delays and bodies
that are malformed but still validly signed (001 webhooks.md). Reconciliation (US3) will record
the same payment facts by a second path. RentSync must keep each PMS fact exactly once
(FR-010, FR-016) and keep the exact bytes it received (FR-013). It may answer `200` only after
the fact is durable (FR-011), and it must account for every delivery, including refused ones
(FR-012).

The constitution requires raw events to be immutable (I) and idempotency to be enforced by
constraints rather than code (II). Its VII requires signatures to be verified before a body is
trusted.

## Decision

- **Verify, then parse, then record.** `POST /webhooks/pms` is a plain Rack endpoint ahead of
  Grape. It reads at most 256 KiB of raw bytes and checks `PMS-Signature` with a constant-time
  comparison, then the 300 s window. Only after that does it parse the envelope. The order and
  the HTTP status for each reason are in contracts/webhook-receiver.md.
- **The database deduplicates.** `raw_events` has two unique keys per PMS client:
  - `event_id`, the PMS's documented deduplication key;
  - a partial `business_key` (`payment.created:<pay_id>`, `payment.reversed:<pay_id>`). It
    covers facts that the other path saw first.

  One `INSERT … ON CONFLICT DO NOTHING` with no conflict target covers both keys. On a conflict,
  the stored row decides the outcome:
  - same event ID and same SHA-256 of the body: `duplicate`;
  - same event ID with a different body: `conflicting_duplicate`, and the first version stands;
  - a business-key match: always `duplicate`, recording which path saw it first, because a
    reconciled payload has different bytes by design.
- **Raw events are immutable.** The exact bytes are in `payload_raw`, with a parsed `jsonb` copy
  for queries. A trigger refuses `UPDATE` and `DELETE`.
- **One receipt for every delivery.** It is written in the same transaction as the raw event.
  It holds the outcome, the reason, the body's length and SHA-256, never the body. A failure
  after the insert rolls both back and answers `500`; an `internal_error` receipt is then
  written on its own, best effort, so the PMS's retry is still visible.
- **Health figures are queries over these rows** (R10), not counters. Metrics are for telemetry
  only.

## Alternatives considered

- **Deduplicate in code with a lookup before the insert.** This races between two deliveries
  of the same event. Constitution II asks for a constraint.
- **Deduplicate on business keys only.** That loses the documented event-ID rule for lease
  events, where one lease legitimately produces many events.
- **Update a reconciled row when its webhook arrives.** This breaks immutability.
- **Answer `200` to malformed deliveries to stop retries.** That would acknowledge something not
  recorded. Each retry is recorded as its own rejection instead: noisy, but honest.
- **Count health figures in Redis.** The counts would be lost on a Redis restart, against
  FR-022, and there would be no audit trail per delivery.
- **Store rejected bodies for debugging.** That would let anyone who can reach the endpoint store
  content, and those bodies may carry tenant data. Only the length and digest are kept.

## Consequences

- Any number of deliveries of one event produce one raw event, and the database guarantees it
  across processes and hosts.
- A test event sent with a valid signature is permanent, so `bin/send_test_webhook` refuses one
  without `--record`.
- Receipts grow with every delivery, retries included. They are purged after 90 days (T054).
  Raw events are never purged.
- Only the active PMS registration's signing secret is accepted. After a re-registration,
  deliveries signed with the old secret get `bad_signature` until the PMS switches over.
