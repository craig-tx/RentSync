# Feature Specification: PMS Connection and Webhook Ingestion

**Feature Branch**: `003-pms-ingestion`

**Created**: 2026-10-28

**Status**: Draft

**Input**: User description: "Build the RentSync integration layer. An operator connects their PMS account through OAuth; RentSync stores the tokens securely and refreshes them automatically. RentSync receives PMS webhooks, verifies their signatures, and records each raw event exactly once even when it is delivered multiple times or out of order. A periodic reconciliation job pulls payments through the PMS API (respecting rate limits and backing off on 429s) to catch anything webhooks missed. Operators can see connection health: last successful sync, token status, events received, events rejected, and why."

This is the kickoff's feature 002. It is numbered 003 because the AWS deployment took 002
(roadmap set 2026-10-20). The PMS it connects to is the mock PMS from feature 001.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connect a PMS account (Priority: P1)

An operator signs in to RentSync and chooses to connect their PMS account. They are sent to
the PMS, sign in there, and approve RentSync's access. They come back to RentSync and see the
connection as active. From then on RentSync can read that operator's PMS data without asking
them again, even though PMS access expires every few minutes.

**Why this priority**: nothing else in RentSync works without a connection. Every later
feature reads data that arrives through it.

**Independent Test**: sign in as a seeded operator, connect to the mock PMS, then leave
RentSync running for several access-token lifetimes and confirm it can still read that
operator's data with no further action.

**Acceptance Scenarios**:

1. **Given** an operator with no connection, **When** they start a connection and approve it
   on the PMS, **Then** RentSync shows the connection as active, names the PMS account it is
   connected to, and records when it was connected.
2. **Given** an operator who starts a connection, **When** they deny access on the PMS,
   **Then** RentSync shows that the connection was not made and why, and stores nothing.
3. **Given** an active connection whose access has expired, **When** RentSync next needs PMS
   data, **Then** it renews access on its own and the read succeeds.
4. **Given** an active connection, **When** the operator's grant is revoked on the PMS side,
   **Then** RentSync marks the connection as needing reauthorization, stops calling the PMS
   for it, and shows the operator how to reconnect.
5. **Given** an active connection, **When** the operator disconnects it, **Then** RentSync
   discards the stored PMS credentials and stops syncing; events already recorded are kept.
6. **Given** an operator, **When** they view connections, **Then** they see only their own.

---

### User Story 2 - Record every PMS event exactly once (Priority: P1)

The PMS pushes events (payment created, payment reversed, lease updated, tenant moved out) to
RentSync. RentSync accepts only deliveries that are genuinely from the PMS, and records each
event once, however many times it is delivered and in whatever order.

**Why this priority**: the ledger (next feature) is built from these raw events. A duplicate
or missing event becomes a wrong balance.

**Independent Test**: with the mock PMS's chaos settings on (duplicates, out-of-order,
delays, server errors, malformed payloads), run the month-end payment burst scenario and
compare RentSync's recorded events with the PMS's event list: every event appears exactly
once, and every bad delivery appears in the rejected list with a reason.

**Acceptance Scenarios**:

1. **Given** a correctly signed delivery of a new event for a connected operator, **When**
   RentSync receives it, **Then** it records the raw event and acknowledges success.
2. **Given** an event already recorded, **When** the same event is delivered again,
   **Then** RentSync acknowledges success and records nothing new, but counts the duplicate.
3. **Given** events delivered out of order, **When** RentSync receives them, **Then** each is
   recorded with both the time it occurred and the time it arrived, and none is refused for
   arriving late.
4. **Given** a delivery with a missing or wrong signature, or a timestamp outside the allowed
   window, **When** RentSync receives it, **Then** it refuses it, records the rejection and
   its reason, and processes nothing from its body.
5. **Given** a correctly signed delivery whose body is malformed, **When** RentSync receives
   it, **Then** it refuses it and records the rejection with the reason.
6. **Given** a correctly signed event for an operator with no active connection, **When**
   RentSync receives it, **Then** it records the rejection with the reason.
7. **Given** RentSync fails partway through recording an event, **When** the PMS retries the
   delivery, **Then** the event ends up recorded exactly once.

---

### User Story 3 - Catch what webhooks missed (Priority: P2)

On a regular schedule, RentSync reads each active connection's recent payments through the
PMS API and records any payment or reversal it has not seen, so a lost webhook never becomes
a missing payment. It does this politely: it stays within the PMS's rate limits and backs off
when told to.

**Why this priority**: webhooks get lost in practice. Without reconciliation, the ledger would
quietly drift from the PMS.

**Independent Test**: make the mock PMS drop some deliveries (exhaust retries against a
RentSync that is down), bring RentSync back, run reconciliation, and confirm every payment in
the PMS is recorded once, with the ones found by reconciliation marked as such.

**Acceptance Scenarios**:

1. **Given** a payment the PMS has but RentSync never received by webhook, **When**
   reconciliation runs, **Then** RentSync records it once and marks it as found by
   reconciliation.
2. **Given** a payment RentSync already recorded from a webhook, **When** reconciliation sees
   it, **Then** nothing new is recorded.
3. **Given** reconciliation recorded a payment first, **When** the webhook for that payment
   arrives later, **Then** it is recognized as the same payment and nothing is double-counted.
4. **Given** a payment that was reversed in the PMS without RentSync receiving the reversal,
   **When** reconciliation runs, **Then** the reversal is recorded.
5. **Given** the PMS answers "too many requests" with a wait time, **When** reconciliation is
   running, **Then** RentSync waits at least that long before trying again, and finishes the
   run once allowed.
6. **Given** reconciliation is interrupted, **When** it runs next, **Then** it picks up from
   where it got to and the end state is the same as an uninterrupted run.
7. **Given** several RentSync instances running, **When** a reconciliation is due, **Then**
   only one run per connection happens at a time.

---

### User Story 4 - See connection health (Priority: P2)

An operator opens their connection's health view and can tell at a glance whether data is
flowing: when RentSync last synced successfully, whether its PMS access is healthy, how many
events it has received, and how many it rejected and why.

**Why this priority**: when numbers look wrong later, the first question is "is the data
coming in?" This answers it without anyone reading logs.

**Independent Test**: produce a known mix of good, duplicate and bad deliveries plus one
reconciliation run, then check that the health view's counts and reasons match exactly.

**Acceptance Scenarios**:

1. **Given** an active connection, **When** the operator views its health, **Then** they see
   the last successful sync time, the access status (active, renewing failed, needs
   reauthorization, disconnected), events received, duplicates ignored, events rejected, and
   the rejections broken down by reason.
2. **Given** rejected events, **When** the operator looks at them, **Then** they see each
   rejection's time, reason and event type where known, without tenant personal details.
3. **Given** reconciliation has failed repeatedly, **When** the operator views health,
   **Then** the view says so, with the last error and when it last succeeded.
4. **Given** two operators, **When** each views health, **Then** each sees only their own
   connection's figures.

---

### Edge Cases

- A delivery's signature is valid but it is a replay of an old delivery outside the timestamp
  window: rejected as stale.
- The same event ID arrives with a different body: the first recorded version stands; the
  conflict is recorded as a rejection ("conflicting duplicate") for investigation.
- Two RentSync instances try to renew the same connection's access at the same moment: the
  PMS invalidates a refresh credential once used, so only one renewal may happen, and the
  connection must not end up broken by the race.
- Access renewal fails for a temporary reason (PMS down, server error): the connection is
  retried with backoff and shown as "renewal failing", not marked as needing reauthorization.
- The operator reconnects after a revocation: the new connection continues the same history;
  events already recorded are not recorded again.
- A webhook arrives for an operator connected under a different RentSync operator account:
  it is attributed only to the operator whose connection it matches.
- The PMS is unreachable for hours: reconciliation keeps failing visibly and recovers on its
  own; nothing recorded is lost.
- A very large backlog after downtime: reconciliation spreads its calls within the rate limit
  rather than failing.

## Requirements *(mandatory)*

### Functional Requirements

**Connections**

- **FR-001**: Operators MUST sign in to RentSync with their own RentSync account (email and
  password) before they can manage connections. Accounts are seeded; self-service sign-up,
  password reset and multi-factor sign-in are out of scope. Sign-in failures are rate limited
  and passwords are stored only as one-way hashes. Every connection belongs to exactly
  one RentSync operator.
- **FR-002**: An operator MUST be able to connect a PMS account through the PMS's
  authorization flow, and RentSync MUST protect the flow against forged or replayed
  callbacks.
- **FR-003**: RentSync MUST store PMS access and refresh credentials encrypted at rest, and
  MUST NOT write them to logs, metrics, error messages or telemetry.
- **FR-004**: RentSync MUST renew expired access automatically, before or when it is needed,
  with no operator action.
- **FR-005**: Renewal MUST be safe with several RentSync instances running: at most one
  renewal per connection at a time, and a renewal race MUST NOT invalidate the connection.
- **FR-006**: When the PMS reports the grant is revoked or the refresh credential invalid,
  RentSync MUST mark the connection as needing reauthorization and stop calling the PMS for
  it. Temporary failures MUST NOT do this.
- **FR-007**: An operator MUST be able to disconnect. Disconnecting MUST delete the stored
  credentials and keep recorded events.
- **FR-008**: One operator has at most one active connection per PMS account; connecting the
  same PMS account again replaces the old credentials and keeps the history.

**Webhook ingestion**

- **FR-009**: RentSync MUST verify every delivery's signature over the exact body received
  and its timestamp, before reading anything from the body, and MUST refuse deliveries whose
  timestamp is more than 5 minutes from RentSync's clock.
- **FR-010**: RentSync MUST record each accepted event once, keyed on the PMS's identity and
  the event's ID, enforced by the data store itself and not only by code.
- **FR-011**: RentSync MUST acknowledge a delivery as successful only after the event is
  durably recorded (or found already recorded), so the PMS retries anything not recorded.
- **FR-012**: Every refused delivery MUST be recorded with a reason code (at least: bad
  signature, stale timestamp, malformed body, unknown operator, no active connection,
  conflicting duplicate) and counted. Its body is not trusted or processed.
- **FR-013**: Each recorded event MUST keep the original payload exactly as received, the
  time it occurred, the time it arrived, how it arrived (webhook or reconciliation), and a
  correlation ID that later processing carries forward.
- **FR-014**: Event recording MUST NOT depend on arrival order. Ordering is resolved by the
  ledger (next feature) using the occurrence time.

**Reconciliation**

- **FR-015**: RentSync MUST periodically read each active connection's payments and
  reversals through the PMS API, covering at least the period since the last successful
  reconciliation plus an overlap, and record any it has not seen.
- **FR-016**: A payment or reversal MUST be recorded once whether a webhook or reconciliation
  sees it first; the business record's PMS identity is the deduplication key across both
  paths.
- **FR-017**: Reconciliation MUST honor the PMS's rate limits: on "too many requests" it waits
  at least the time the PMS asks for, and retries with increasing, randomized delays.
- **FR-018**: Reconciliation MUST be resumable and idempotent: an interrupted or repeated run
  produces the same end state as one clean run.
- **FR-019**: At most one reconciliation per connection MUST run at a time, across all
  instances.
- **FR-020**: Operators MUST be able to trigger a reconciliation for their connection on
  demand, in addition to the schedule.

**Connection health**

- **FR-021**: For each connection, RentSync MUST show: status, last successful sync (webhook
  or reconciliation), last reconciliation result, events received, duplicates ignored, events
  rejected, rejections by reason, and the most recent rejections.
- **FR-022**: Health figures MUST be correct across several instances and survive restarts.
- **FR-023**: Operators MUST see only their own connections, events and health; this MUST be
  enforced on the server.
- **FR-024**: Rejections, duplicates, renewals and reconciliation runs MUST also be visible
  as telemetry (constitution VI), with no tenant personal data or credentials in it.

**Delivery**

- **FR-025**: This feature MUST deploy RentSync (its API and background worker) to the
  existing staging and production deployments, alongside the mock PMS, through the existing
  release pipeline, so the webhook path runs live. Each deployment MUST have its own RentSync
  data, credentials and signing secret, and stay healthy within the host size it runs on.

### Key Entities

- **Operator account**: a RentSync user representing a property management company.
- **PMS connection**: links an operator account to one PMS account. Holds the encrypted
  credentials, their expiry, the status, and the reconciliation progress marker.
- **Raw event**: one PMS event exactly as received: PMS identity, event ID, type, occurrence
  time, arrival time, arrival path, payload, correlation ID. Never changed after recording.
- **Rejected delivery**: one refused delivery: time, reason code, event type and ID where
  readable, connection where known. No trusted payload content.
- **Reconciliation run**: one run for one connection: start, end, outcome, records seen,
  records added, rate-limit waits, error.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator connects a PMS account in under 2 minutes, from starting to seeing
  it active.
- **SC-002**: Over 24 hours of running with 5-minute PMS access, a connection needs no
  operator action and no PMS read fails for lack of valid access.
- **SC-003**: With every mock PMS chaos setting on, after a month-end payment burst and one
  reconciliation, RentSync's recorded events match the PMS exactly: zero duplicates and zero
  missing.
- **SC-004**: With 10% of deliveries permanently lost, one reconciliation run recovers 100% of
  the missing payments and reversals.
- **SC-005**: 100% of refused deliveries appear in the health view with a reason; none is
  dropped silently.
- **SC-006**: The PMS gets its acknowledgement for 95% of deliveries within 2 seconds, so its
  retries are not triggered by slowness.
- **SC-007**: Reconciliation never exceeds the PMS's rate limit by more than the requests in
  flight when a "too many requests" answer arrives, and always completes once allowed.
- **SC-008**: Health figures are up to date within 1 minute of the events they count.

## Assumptions

- **One PMS**: the only PMS is the mock PMS from feature 001. The design allows others, but
  only one is built.
- **RentSync is one client of the PMS**: it registers once, with one subscriber address that
  receives events for all connected operators, and one signing secret (feature 001
  assumptions).
- **Raw events only**: this feature records raw events. Turning them into ledger entries,
  ordering them, and matching them is the next feature (kickoff's 003). The constitution's
  end-to-end test "to the persisted ledger effect" therefore ends at the recorded raw event
  here, and is extended when the ledger exists.
- **Read-only**: RentSync never writes to the PMS.
- **Schedule**: reconciliation runs every 15 minutes per connection by default, with a
  configurable interval and overlap window.
- **Retention**: raw events are kept indefinitely, since every ledger figure must trace back
  to them. Rejected deliveries are kept for 90 days.
- **Timestamp window**: 5 minutes, a common default for signed webhooks; the hosts' clocks
  are kept in sync (feature 002).
- **Clarified 2026-10-28**: operators sign in with RentSync accounts (FR-001); this feature
  deploys RentSync to staging and production (FR-025).
- **Health view**: a minimal view is enough; the full operator dashboard is a later feature.
- **Synthetic data**: all data comes from the mock PMS seed and scenarios.
