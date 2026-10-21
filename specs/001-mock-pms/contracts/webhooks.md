# Webhook Contract: Mock PMS → Subscriber

This is the contract between the mock PMS and a subscriber (RentSync, feature 002). The
background for each decision is in research R6, R7, and R10.

## Transport

- Each delivery is sent as `POST {client.subscriber_url}` with
  `Content-Type: application/json; charset=utf-8`.
- One event is sent per request. Events are never batched.
- A delivery succeeds when the subscriber returns any `2xx` within **10 s**. Any other
  outcome is a failure and is retried.
- Delivery is **at-least-once**. Subscribers MUST deduplicate on `PMS-Event-Id`.
- Without chaos, deliveries are sent in `occurred_at` order for each client. This ordering
  is not guaranteed once chaos is on or a retry happens. Subscribers MUST NOT depend on
  arrival order.

## Headers

| Header | Example | Meaning |
|---|---|---|
| `PMS-Event-Id` | `evt_6M2Q...` | Stable for the life of the event. It stays the same across retries, chaos duplicates, and replays. **This is the deduplication key.** |
| `PMS-Event-Type` | `payment.created` | Matches `type` in the body |
| `PMS-Delivery-Id` | `dlv_9TQ1...` | Unique to each delivery. A chaos duplicate and a replay each get a new delivery ID |
| `PMS-Delivery-Attempt` | `3` | Starts at 1 and counts attempts within one delivery |
| `PMS-Replay` | `true` | Present only on admin replays |
| `PMS-Signature` | `t=1792540800,v1=5f2b...` | See [Signature](#signature) |
| `X-Correlation-Id` | `c0a8...` | The correlation ID of the request or scenario that caused the event |

## Signature

```
signed_payload = "<t>" + "." + <raw request body bytes>
v1             = hex( HMAC-SHA256( key = client.signing_secret, data = signed_payload ) )
PMS-Signature  = "t=<t>,v1=<v1>"
```

- `t` is the Unix time in seconds when **this attempt** was sent, so it changes on every
  retry.
- The signature covers the **exact bytes sent**, including bodies that chaos has malformed.
  That means a malformed body still verifies, and the subscriber's parser and schema checks
  are what must reject it.

The subscriber verifies a delivery as follows:

1. Parse the `t` and `v1` values from the header.
2. Recompute the signature and compare it in constant time.
3. Reject the delivery if `|now - t|` is larger than the subscriber's tolerance. Feature 002
   decides the tolerance; 300 s is suggested.

**Test vector** (fixed, for unit tests on both sides):

```
secret = "whsec_test_0123456789abcdef"
t      = 1792540800
body   = {"id":"evt_TEST","type":"payment.created"}
```

The expected `v1` is computed and frozen in `mock_pms/spec/fixtures/signature_vector.json` by
the first test-first task. Feature 002 reuses that fixture.

## Envelope

```json
{
  "id": "evt_6M2Q4ZJ7B1XKQ0R9T3VA",
  "type": "payment.created",
  "occurred_at": "2026-10-31T14:05:12Z",
  "operator_id": "op_3H8...",
  "api_version": "2026-10-01",
  "data": { "object": { } }
}
```

| Field | Rules |
|---|---|
| `id` | Same value as `PMS-Event-Id` |
| `type` | One of the four types below |
| `occurred_at` | When the business change happened. For seeded history this can be months in the past. Use it, not arrival time, to order events |
| `operator_id` | The operator whose data changed |
| `api_version` | A fixed string. It changes only if the payload shapes change |
| `data.object` | A full snapshot of the affected resource at `occurred_at`, in the same shape as its `/v1` representation ([openapi.yaml](openapi.yaml)) |

## Event types

| Type | Emitted when | `data.object` |
|---|---|---|
| `payment.created` | A payment is recorded (by the seed, a scenario, or admin) | `Payment`, with `status: settled` and `applied_to` |
| `payment.reversed` | A settled payment is reversed (NSF and similar) | `Payment`, with `status: reversed` and a `reversal` object filled in. The `id` is the original payment's ID |
| `lease.updated` | Any lease field changes, including `status` and `actual_end_date` | `Lease` |
| `tenant.moved_out` | A lease ends early because of a move-out | `{ "tenant": Tenant, "lease": Lease, "move_out_date": "YYYY-MM-DD" }` |

A move-out emits `lease.updated` and then `tenant.moved_out`, with the same `occurred_at` and
`X-Correlation-Id`.

## Retries

- After a failure, attempt *n* is retried after `RETRY_BASE_SECONDS × 2^(n−1)` ± 10% jitter.
  The default base is 2 s, which gives 2, 4, 8, 16, 32, 64, and 128 s.
- After `MAX_ATTEMPTS` attempts (default 8), the delivery is marked `exhausted` and is no
  longer retried automatically. It can still be replayed through
  `POST /admin/events/{id}/replay`.
- A delivery stuck `in_flight` for more than 60 s, for example after a worker crash, goes back
  to `pending`. This can produce a repeat delivery with the same `PMS-Delivery-Id` and a
  higher attempt number.

## Chaos effects visible to subscribers

| Setting | What the subscriber sees |
|---|---|
| `duplicate_rate` | The same event (same `PMS-Event-Id`, same underlying event content) arrives in two deliveries, each with its own `PMS-Delivery-Id`. Each copy gets its own malformation decision, so one copy can be well-formed while the other is malformed |
| `out_of_order_rate` | The delivery is held 2–10 s, so later events can arrive first |
| `delay_rate` with `delay_min_s`/`delay_max_s` | The delivery is held for a random time within the range |
| `malformed_rate` | The body is one of: truncated JSON (`truncate`); missing `data` (`drop_field`); or `occurred_at` sent as a number (`bad_type`). The signature is still valid |
| `server_error_rate` | Affects `/v1/*` API responses only, not webhooks |

Chaos never changes stored data. `GET /admin/events` always returns the true, well-formed
events, so a test can compare what the subscriber recorded against them.
