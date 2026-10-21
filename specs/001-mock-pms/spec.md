# Feature Specification: Mock Property Management System (PMS)

**Feature Branch**: `001-mock-pms`

**Created**: 2026-10-20

**Status**: Draft

**Input**: User description: "Build a simulated property management system (PMS) that stands in for real platforms like the ones SFR operators use. It must: act as an OAuth 2.0 authorization server (authorization code flow with refresh tokens; access tokens expire quickly so refresh logic is exercised); hold seed data: ~3 operators, ~50 properties, ~60 tenants and leases, and 12 months of rent charges and payments, including partial payments, late payments, NSF reversals, and a few tenants who move out mid-lease; expose a REST API for properties, leases, tenants, charges, and payments, with pagination and per-client rate limits that return 429 with Retry-After; send signed webhooks (HMAC) for payment.created, payment.reversed, lease.updated, and tenant.moved_out to a registered subscriber URL; include configurable "chaos" settings: duplicate delivery rate, out-of-order delivery, delayed delivery, occasional 500s, and malformed payloads, so the consumer's resilience can be demonstrated; provide a small admin endpoint to replay events and to trigger a scenario (for example, 'simulate month-end payment burst'). This is a test harness, not a product: keep it small, but realistic."

## Overview

The mock PMS is a stand-in for the property management platforms that single-family rental
(SFR) operators use. It exists so that RentSync's integration layer (feature 002) and
everything built on it can be developed, tested, and demonstrated against realistic, hostile
third-party behavior without access to a real vendor.

Its "users" are:

- **Integration client**: a connecting application (RentSync) that authorizes against the mock
  PMS, reads data through its API, and receives its webhooks.
- **Operator (simulated)**: a seeded property operator who grants or denies the integration
  client access to their account.
- **Developer / demo presenter**: the person running the harness, who configures chaos
  settings, replays events, and triggers scenarios to show how the client copes.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connect and read a realistic portfolio (Priority: P1)

A developer registers an integration client with the mock PMS, sends a seeded operator through
the authorization flow, and uses the resulting access to read that operator's properties,
tenants, leases, charges, and payments page by page. The data looks like a real 12-month rent
history, including the messy cases a real portfolio has.

**Why this priority**: Every later RentSync feature depends on being able to connect to a PMS
and read data from it. Without authorized, realistic, paginated data there is nothing to sync.

**Independent Test**: Start a fresh harness, complete the authorization flow as one seeded
operator, page through every resource type, and confirm the counts and data mix match the
seed profile and that no other operator's data is visible.

**Acceptance Scenarios**:

1. **Given** a registered integration client and a seeded operator, **When** the operator
   approves access in the authorization flow, **Then** the client receives an authorization
   code that it can exchange once for an access token and a refresh token.
2. **Given** a valid access token for operator A, **When** the client lists properties,
   tenants, leases, charges, or payments, **Then** only operator A's records are returned, in
   pages, with a way to request the next page until all records have been retrieved.
3. **Given** an access token that has expired, **When** the client calls the API, **Then** the
   request is rejected as unauthorized, and **When** the client presents its refresh token,
   **Then** it receives a new working access token.
4. **Given** a fresh harness, **When** the seed data is loaded, **Then** it contains the
   portfolio described in FR-010 to FR-013, including partial payments, late payments, NSF
   reversals, and mid-lease move-outs.
5. **Given** the operator denies access in the authorization flow, **Then** no code or token is
   issued and the client is told access was denied.

---

### User Story 2 - Receive signed webhooks for business events (Priority: P1)

A developer registers a subscriber address for an integration client. When payments are made
or reversed, leases change, or tenants move out in an operator account the client is
connected to, the mock PMS sends a signed event notification to that address. The receiver
can verify that each notification really came from the mock PMS and was not altered.

**Why this priority**: Webhook ingestion is the core of RentSync's integration layer. Signed,
realistic events are needed before idempotency or ordering can be demonstrated.

**Independent Test**: Register a test receiver, trigger one event of each type, and confirm
each notification arrives with a valid signature, a unique event ID, an event type, a
timestamp, and a payload describing the affected record.

**Acceptance Scenarios**:

1. **Given** a client with a registered subscriber address and a connected operator, **When**
   a payment is created for that operator, **Then** a `payment.created` notification is sent
   to the subscriber address within 5 seconds (with chaos disabled).
2. **Given** the same setup, **When** a payment is reversed, a lease is updated, or a tenant
   moves out, **Then** a `payment.reversed`, `lease.updated`, or `tenant.moved_out`
   notification is sent.
3. **Given** a delivered notification, **When** the receiver computes the signature using the
   client's shared signing secret, **Then** it matches the signature sent with the
   notification, and any change to the body makes the check fail.
4. **Given** the subscriber responds with an error or does not respond, **When** delivery
   fails, **Then** the mock PMS retries the same event (same event ID) on a backoff schedule
   until it succeeds or the retry limit is reached, and records each attempt.
5. **Given** events for operator B, **When** a client is connected only to operator A,
   **Then** the client receives no notifications about operator B.

---

### User Story 3 - Hit realistic rate limits (Priority: P2)

A developer calls the API faster than the per-client allowance. The mock PMS starts refusing
requests with a "too many requests" response that says how long to wait, and accepts requests
again once that time has passed.

**Why this priority**: RentSync's reconciliation job must respect rate limits and back off.
This needs a PMS that enforces them predictably.

**Independent Test**: Send requests from one client faster than its configured limit, confirm
throttled responses carry a wait time, wait that long, and confirm requests succeed again. A
second client is unaffected.

**Acceptance Scenarios**:

1. **Given** a client limit of N requests per window, **When** the client makes request N+1
   within the window, **Then** it receives a "too many requests" (429) response with a
   Retry-After value.
2. **Given** a throttled client, **When** it waits for the Retry-After time and tries again,
   **Then** the request succeeds.
3. **Given** client X is throttled, **When** client Y makes requests within its own limit,
   **Then** client Y's requests succeed.

---

### User Story 4 - Turn on chaos to stress the consumer (Priority: P2)

A demo presenter turns on chaos settings: some webhooks are delivered twice, some arrive out
of order or late, some API calls fail with server errors, and some webhook bodies are
malformed. The presenter can show that RentSync's ledger stays correct regardless.

**Why this priority**: The finish line includes a chaos demo. This is the feature that makes
"integrations are hostile by default" (Constitution Principle IV) demonstrable.

**Independent Test**: With a test receiver, set each chaos setting to a known rate, generate
a large batch of events, and confirm the observed duplicate, reorder, delay, error, and
malformed rates match the configured rates within tolerance. Then turn chaos off and confirm
normal behavior returns.

**Acceptance Scenarios**:

1. **Given** a duplicate delivery rate of D%, **When** many events are generated, **Then**
   roughly D% of events are delivered more than once with the same event ID and identical
   content.
2. **Given** out-of-order delivery is on, **When** a burst of related events is generated,
   **Then** some events reach the subscriber in a different order from the one they occurred
   in, while each event's own timestamp still reflects when it occurred.
3. **Given** a delivery delay setting, **When** events are generated, **Then** affected events
   are held back by a random time within the configured range before delivery.
4. **Given** a server-error rate of E%, **When** the client calls the API, **Then** roughly E%
   of otherwise-valid requests fail with a server error, and a retry of the same request can
   succeed.
5. **Given** a malformed-payload rate of M%, **When** events are delivered, **Then** roughly M%
   of deliveries contain a body that cannot be parsed or is missing required fields. They are
   still signed over the body actually sent.
6. **Given** all chaos settings are zero, **Then** every event is delivered exactly once, in
   order, without delay or corruption.

---

### User Story 5 - Replay events and trigger scenarios (Priority: P3)

A developer or demo presenter uses a small admin interface to resend past events, either one
at a time or all events in a time range, and to trigger named scenarios. One example is
"month-end payment burst", where many tenants pay in a short window.

**Why this priority**: Replay is how missed webhooks are recovered and demonstrated, and
scenarios make demos repeatable. Both rely on stories 1, 2, and 4.

**Independent Test**: Replay a known past event and confirm it arrives again with its original
event ID. Then trigger the month-end burst scenario and confirm the expected volume of new
payment events is created and delivered.

**Acceptance Scenarios**:

1. **Given** a previously sent event, **When** the admin replays it, **Then** it is delivered
   again with the same event ID and content and is marked as a replay in the delivery log.
2. **Given** a time range, **When** the admin replays that range for a client, **Then** every
   event in the range for that client's connected operators is redelivered.
3. **Given** the "month-end payment burst" scenario, **When** the admin triggers it, **Then**
   payments are recorded against open charges for a large share of active leases within a
   short window, and the matching `payment.created` events are sent, subject to the current
   chaos settings.
4. **Given** a caller without admin credentials, **When** it calls any admin function,
   **Then** the request is refused.

---

### Edge Cases

- **Authorization code reuse**: a second exchange of the same code is rejected.
- **Refresh token reuse**: once a refresh token has been used, it MUST stop working, and
  further attempts with it are rejected.
- **Revoked access**: if an operator revokes a client's access, both its access and refresh
  tokens stop working immediately.
- **Pagination under change**: if records are added while a client is paging, paging still
  completes without skipping or repeating records that existed when paging began.
- **Rate limit during burst**: a scenario burst does not consume a client's API rate limit.
  Only the client's own requests count.
- **No subscriber registered**: events are still recorded and can be replayed later, but no
  delivery is attempted.
- **Subscriber unreachable for a long time**: once the retry limit is reached, the event is
  marked as undelivered and stays available for replay.
- **Reversal of a partial payment**: an NSF reversal references the original payment and
  reverses its full amount, even when the payment only partly covered its charge.
- **Move-out mid-lease**: after a move-out, the lease shows an end date earlier than the
  original term, and no new rent charges are generated after it.
- **Malformed payload combined with duplicate**: when both chaos effects apply to one event,
  the duplicate copy may be well-formed or malformed. Each copy carries the same event ID.
- **Admin replay of an event for a disconnected operator**: the replay is refused, with a
  reason.

## Requirements *(mandatory)*

### Functional Requirements

**Authorization (OAuth 2.0 authorization server)**

- **FR-001**: The system MUST let a developer register an integration client with a client
  identifier, a client secret, one or more allowed redirect addresses, and an optional
  webhook subscriber address.
- **FR-002**: The system MUST support the OAuth 2.0 authorization code flow. A seeded operator
  signs in on a simple approval page and approves or denies the client's request, and an
  approval returns a single-use, short-lived authorization code to a registered redirect
  address.
- **FR-003**: The system MUST exchange a valid authorization code, together with the client's
  credentials, for an access token and a refresh token scoped to that operator.
- **FR-004**: Access tokens MUST expire after a short, configurable lifetime (default 5
  minutes) so that client refresh logic is regularly exercised.
- **FR-005**: The system MUST exchange a valid refresh token for a new access token and a new
  refresh token, and MUST invalidate the refresh token that was used.
- **FR-006**: The system MUST reject expired, revoked, malformed, or unknown tokens with an
  unauthorized response. The response MUST distinguish an expired token from an invalid one.
- **FR-007**: The system MUST let an operator's access grant to a client be revoked through
  the admin interface, which immediately invalidates that grant's tokens.

**Data access API**

- **FR-008**: The system MUST expose read access to properties, tenants, leases, charges, and
  payments, limited to the operator the access token was issued for.
- **FR-009**: Every list MUST be paginated with a stable ordering and a continuation marker. It
  MUST support a page size up to a documented maximum, and MUST support filtering charges and
  payments by date range or by "updated since" a point in time.
- **FR-010**: Every record MUST have a stable, unique identifier and created and last-updated
  timestamps. Amounts MUST be stated in whole cents with a currency code.

**Seed data**

- **FR-011**: The system MUST load a seed portfolio of about 3 operators, about 50 properties,
  and about 60 tenants and leases, distributed unevenly across operators.
- **FR-012**: The seed MUST contain 12 months of monthly rent charges and payments ending in
  the current month. The history MUST include:
  - on-time payments,
  - late payments (several distinct delays),
  - partial payments, some later completed and some never completed,
  - NSF reversals of earlier payments,
  - at least 3 tenants who move out before their lease term ends.
- **FR-013**: Seed generation MUST be deterministic for a given seed value, so that the same
  value always produces identical data.
- **FR-014**: The system MUST let a developer reset all data to the initial seed state.

**Webhooks**

- **FR-015**: The system MUST record an event whenever a payment is created, a payment is
  reversed, a lease is updated, or a tenant moves out. The corresponding event types are
  `payment.created`, `payment.reversed`, `lease.updated`, and `tenant.moved_out`.
- **FR-016**: Each event MUST carry a globally unique event ID, its type, the time the
  business change occurred, the operator it belongs to, and a snapshot of the affected
  record.
- **FR-017**: The system MUST deliver each event to the subscriber address of every client
  that holds an active grant for the event's operator.
- **FR-018**: Every delivery MUST be signed using HMAC-SHA256 over the exact body sent and a
  delivery timestamp, keyed with a signing secret unique to the client. The signature and
  timestamp MUST be sent with the delivery.
- **FR-019**: A delivery counts as successful only when the subscriber acknowledges it with a
  success response. Failed deliveries MUST be retried with increasing delays up to a
  configurable limit (default 8 attempts). Every retry keeps the same event ID.
- **FR-020**: The system MUST keep a delivery log recording each attempt: event ID, client,
  attempt number, time, outcome, whether chaos was applied, and whether it was a replay.

**Rate limiting**

- **FR-021**: The system MUST enforce a configurable request limit for each client (default 60
  requests per minute). Requests over the limit MUST receive a 429 response with a Retry-After
  value in seconds.
- **FR-022**: Rate limits MUST apply to each client independently, and admin functions MUST NOT
  count against any client's limit.

**Chaos settings**

- **FR-023**: The system MUST provide adjustable chaos settings, changeable at runtime without a
  restart, for:
  - the duplicate delivery rate,
  - the out-of-order delivery rate,
  - delayed delivery (a rate plus a delay range),
  - the API server-error rate,
  - the malformed payload rate.
- **FR-024**: All chaos settings MUST default to off. With chaos off, delivery MUST be exactly
  once, in occurrence order, and without injected faults.
- **FR-025**: Chaos MUST apply only to delivery and responses, never to stored data. Event
  records and business data MUST stay correct, so that the "true" state is always available
  for comparison.
- **FR-026**: The system MUST let chaos randomness be seeded, so that a given seed and a given
  sequence of actions reproduce the same chaos decisions.

**Admin functions**

- **FR-027**: The system MUST provide admin functions that require admin credentials. Admin
  functions MUST be able to:
  - view and change chaos settings,
  - replay a single event,
  - replay all events for a client in a time range,
  - trigger a named scenario,
  - revoke a grant,
  - reset to seed.
- **FR-028**: The system MUST include at least these scenarios:
  - **month-end payment burst**: payments against open charges for a large share of active
    leases within a short window,
  - **NSF wave**: several recent payments reversed,
  - **tenant move-out**: one active tenant moves out mid-lease.
  Each scenario MUST produce the corresponding events.
- **FR-029**: Replayed deliveries MUST keep their original event ID, type, occurrence time, and
  payload, and MUST be marked as replays in the delivery log.

**Operability**

- **FR-030**: The system MUST expose a health check and MUST emit structured logs, each with a
  correlation identifier for every request and every delivery attempt (Constitution Principle
  VI).
- **FR-031**: The system MUST NOT write tokens, client secrets, signing secrets, or unredacted
  tenant personal data to its logs (Constitution Principle VII).

### Key Entities

- **Operator**: a property management company. It owns properties and has sign-in credentials
  for the approval page.
- **Integration Client**: a registered connecting application. It has credentials, allowed
  redirect addresses, an optional subscriber address, a webhook signing secret, and a rate
  limit.
- **Grant**: an operator's authorization of a client. It links an operator, a client, and the
  tokens issued under the grant, and it can be revoked.
- **Property**: a single-family rental home owned by an operator, with an address and a status.
- **Tenant**: a person renting a property, identified by a name and contact details that are
  synthetic in the seed.
- **Lease**: an agreement between a tenant and a property. It records the start date, the
  originally scheduled end date, the actual end date (if the tenant moved out), the monthly
  rent, the due day, and the status.
- **Charge**: an amount owed on a lease for a period, such as monthly rent or a late fee, with
  a due date.
- **Payment**: money received against a lease. It has an amount, a received date, a method, a
  status (settled or reversed), and the charge or charges it was applied to (if any) as the
  PMS reports them.
- **Reversal**: the record of an NSF reversal. It references the original payment and states a
  reason and a date.
- **Event**: an immutable record of a business change. It has an event ID, a type, an
  occurrence time, an operator, and a payload snapshot.
- **Delivery Attempt**: one try at sending an event to a client's subscriber. It records the
  attempt number, time, outcome, chaos effects applied, and the replay flag.
- **Chaos Settings**: the current fault-injection rates and ranges, plus the randomness seed.
- **Scenario**: a named, repeatable script that generates business changes and their events.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer can go from a fresh harness to reading the first page of payments
  with a newly authorized client in under 5 minutes, following only the project
  documentation.
- **SC-002**: A fresh harness is fully seeded and ready in under 1 minute. Reseeding with the
  same seed value produces identical data on every run.
- **SC-003**: With chaos off, 100% of events reach a healthy subscriber exactly once, in
  occurrence order, within 5 seconds of the business change.
- **SC-004**: 100% of deliveries carry a signature that the receiver can verify with the
  client's signing secret, and 100% of altered bodies fail verification.
- **SC-005**: Over at least 1,000 deliveries, every observed chaos rate is within 3 percentage
  points of its configured value.
- **SC-006**: A client exceeding its rate limit is throttled on the first excess request, and
  can make requests successfully again once the Retry-After time has passed.
- **SC-007**: A refresh is needed at least once during any test session that runs longer than
  the access token lifetime.
- **SC-008**: The month-end payment burst scenario generates payments for at least 70% of
  active leases and delivers their events within 2 minutes (with chaos off).
- **SC-009**: Across all API responses and delivered events, no operator ever sees data that
  belongs to another operator.

## Assumptions

- **Scope**: this is a test harness, not a product. It provides read-only data access to
  clients. Clients cannot create or change PMS data through the API; changes come from the
  seed, scenarios, and admin functions. (RentSync only reads from PMS platforms.)
- **Approval page**: the operator approval page is a minimal sign-in-and-approve screen that
  uses seeded operator credentials. It has no account management, password reset, or
  multi-factor authentication.
- **Scopes**: a single access scope ("read everything for this operator") is enough. Finer
  scopes are out of scope.
- **Subscriber address**: there is one subscriber address per client. Events from all of a
  client's connected operators go to that address.
- **Payment application**: the mock PMS reports which charges a payment was applied to, as many
  real PMS platforms do. It is not authoritative, though; RentSync builds its own matching in
  feature 003.
- **Single currency**: all seed amounts are in USD.
- **Seed timeline**: "12 months ending in the current month" is anchored to the date the seed
  is generated. With a fixed seed value and a fixed anchor date, the output is fully
  reproducible.
- **Default limits**: defaults (5-minute access tokens, 60 requests per minute, 8 delivery
  attempts) are configurable and are chosen to exercise client behavior during short demos.
- **Admin credentials**: a single admin secret from local configuration is enough for admin
  authentication.
- **Synthetic data**: all seed data, including names and addresses, is synthetic. No real
  tenant data is ever used (constitution: Scope & Data Constraints).
- **Dependencies**: the mock PMS is consumed by feature 002 (Connection and webhook
  ingestion). It is deployed alongside RentSync for local development and CI (feature 007).
