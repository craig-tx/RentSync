# ADR-0003: Redis-backed token-bucket rate limiter

- **Status:** Accepted
- **Date:** 2026-10-20
- **Feature:** 001-mock-pms (research R8)

## Context

FR-021 and FR-022 require an exact, configurable limit per client on `/v1/*` (default 60 per minute). A request over the limit gets `429` with a `Retry-After` value. Limits apply to each client independently, and admin, OAuth, health and metrics endpoints are exempt. SC-006 asks for throttling on the *first* excess request.

Constitution X (v1.1.0) requires services to be stateless: correctness must not depend on how many instances run or which instance serves a request.

## Decision

Each client gets a token bucket **in Redis** (`mock_pms:rl:<client_id>`, a hash of `tokens` and `ts_ms`), updated by one **Lua script** called with `EVALSHA`. In a single atomic step the script:

1. reads the bucket;
2. refills it continuously, using `elapsed × capacity / window` so that whole-token refills are exact;
3. takes a token, or computes `retry_after_ms`;
4. writes the bucket back and sets `PEXPIRE` to one window plus 1 s.

Further details:

- **Clock:** Redis `TIME` is the single clock for every web instance. Tests pass `now_ms` instead, so they are deterministic without sleeping.
- **Capacity:** the client's `rate_limit_per_minute`, or `RATE_LIMIT_PER_MINUTE` if the client has none.
- **Middleware:** runs before chaos injection and applies only to `/v1/*`. Invalid tokens pass through, so `/v1` answers 401 without spending a token.
- **Fail closed:** if Redis is unreachable, `/v1/*` returns `503 rate_limiter_unavailable` and `/healthz` reports Redis as down.

## Alternatives considered

- **An in-process `Mutex` bucket** (the earlier design). Exact and dependency-free, but it pins the web service to one process, which conflicts with Constitution X.
- **A Postgres counter table.** Adds a database write to every API request, and a fixed window allows bursts at the window boundary.
- **Rack::Attack backed by Redis.** Offers only fixed-window throttles, so `Retry-After` would be the time to the end of the window rather than an exact token wait. It also adds a gem that the 40-line script replaces.
- **A Redis `INCR` + `EXPIRE` fixed window.** Allows bursts of up to twice the limit across a window boundary, and makes "throttled on the first excess request" depend on where the window happens to fall.

## Consequences

- The web tier is stateless. Any number of Puma workers or containers enforce one exact limit per client; quickstart §6 checks this with `mock_pms` and `mock_pms_b`.
- `/v1` depends on Redis. When Redis is down the harness refuses requests rather than silently dropping the behaviour it exists to demonstrate.
- Idle buckets expire on their own, so Redis holds state only for active clients.
