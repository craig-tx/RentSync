# ADR-0002: Hand-written OAuth 2.0 authorization server with opaque, hashed tokens

- **Status:** Accepted
- **Date:** 2026-10-20
- **Feature:** 001-mock-pms (research R3, R4)

## Context

The mock PMS has to act as an OAuth 2.0 authorization server for RentSync's connection work in feature 002. The flow it needs is narrow:

- the `authorization_code` grant, with optional PKCE S256;
- the `refresh_token` grant, with rotation;
- client authentication by `client_secret_basic` or `client_secret_post`;
- one scope (`read`);
- short-lived access tokens, so that client refresh logic is exercised regularly.

Some edge cases must be explicit and testable: reusing a code, reusing a refresh token, telling an expired token apart from an invalid one, and revocation taking effect immediately (FR-005 to FR-007).

The kickoff rules out Rails.

## Decision

Implement the server directly in `MockPms::OAuth::Service`, with opaque random tokens (32 bytes or more) and **only their SHA-256 digests stored**.

- **Single use:** codes (60 s) and refresh tokens (30 days) are claimed with `UPDATE … SET used_at = now WHERE … used_at IS NULL AND expires_at > now`, in the same transaction that issues the new tokens. If no row changes, the result is `invalid_grant`.
- **Validation order:** an unknown digest is invalid, a revoked grant is invalid, and a token past its expiry is expired. The `/v1` API reports this as `WWW-Authenticate: Bearer error="invalid_token", error_description="token expired" | "token invalid"`.
- **Revocation:** revoking sets `grants.revoked_at`, which invalidates every token under that grant at once.
- **Client secrets** are also stored as SHA-256 digests and compared in constant time. **Operator passwords** use bcrypt.

This meets Constitution VII (v1.1.0): a system that only verifies the tokens it issued must store one-way hashes.

## Alternatives considered

- **Doorkeeper.** Requires Rails.
- **`rack-oauth2`.** Mostly client-side building blocks. The state machine would still have to be written by hand.
- **JWT access tokens.** Revocation could not take effect immediately without adding a lookup anyway, so opaque tokens are simpler and meet FR-007 directly.

## Consequences

- The edge-case behaviour is small, fully under test, and specified in `contracts/openapi.yaml`.
- Reusing a refresh token is rejected, but it does not revoke the grant: the spec asks only for rejection. Revoking on reuse would be a one-line change in `refresh!` if feature 002 wants to demonstrate it.
- Adding scopes would mean replacing the single `read` constant with checks per endpoint.
