# Contract: RentSync's Webhook Receiver

The receiving side of feature 001's [webhooks.md](../../001-mock-pms/contracts/webhooks.md).
Decisions are in research R3, R4 and R10.

## Endpoint

`POST https://<app hostname>/webhooks/pms` (locally `http://localhost:4002/webhooks/pms`).
Registered as the PMS client's subscriber URL by `PmsRegistration.ensure!` (R9). No session or
CSRF: the signature is the authentication.

## Processing order

| Step | Check | Failure reason | HTTP |
|---|---|---|---|
| 1 | Body ≤ 256 KiB | `body_too_large` | 413 |
| 2 | `PMS-Signature` present and parseable as `t=<int>,v1=<64 hex>` | `missing_signature` | 401 |
| 3 | `v1` = hex HMAC-SHA256(signing secret, `"<t>.<raw body>"`), constant-time | `bad_signature` | 401 |
| 4 | `abs(now − t) ≤ 300` s | `stale_timestamp` | 401 |
| 5 | Body is a JSON object with `id`, `type` ∈ the four types, `occurred_at` (ISO 8601 string), `operator_id`, `data.object` (object); `id` = `PMS-Event-Id` | `malformed_body` | 422 |
| 6 | An `active` or `renewal_failing` connection exists for `operator_id` | `unknown_operator` (never connected) or `no_active_connection` | 422 |
| 7 | Insert raw event; on a key conflict compare `payload_sha256` | `conflicting_duplicate` when bodies differ | 422 |

Nothing in the body is read before step 3 passes.

## Responses

| Outcome | HTTP | Body |
|---|---|---|
| `recorded` | 200 | `{"outcome":"recorded","event_id":"evt_…"}` |
| `duplicate` | 200 | `{"outcome":"duplicate","event_id":"evt_…"}` |
| `rejected` | 401 / 413 / 422 per the table | `{"error":{"code":"<reason>","message":"…"}}` |
| unexpected error | 500 | `{"error":{"code":"internal_error"}}`: the PMS retries |

`200` is sent only after the transaction that records the raw event (or finds it) and the
receipt has committed (FR-011). Every outcome, including `500` where possible, writes one
`webhook_receipts` row.

Error messages never echo body content, header values or secrets.

## Headers read

`PMS-Signature`, `PMS-Event-Id`, `PMS-Event-Type`, `PMS-Delivery-Id`, `PMS-Delivery-Attempt`,
`PMS-Replay`, `X-Correlation-Id`. A missing `X-Correlation-Id` gets a generated one. The
response carries `X-Correlation-Id`.

## Guarantees to the PMS

- Idempotent: any number of deliveries of one event produce one raw event and `200` each time
  after the first is recorded.
- Order-independent: no event is refused for arriving late or out of order.
- Answers within 2 s at the 95th percentile (SC-006); the 10 s PMS timeout is never approached
  in normal operation.
