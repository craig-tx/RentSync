# Contract Change: Mock PMS Token Response Names the Operator

A backward-compatible extension of feature 001's
[openapi.yaml](../../001-mock-pms/contracts/openapi.yaml), needed by research R7.

## Change

`POST /oauth/token` success responses (both `authorization_code` and `refresh_token` grants)
gain two fields:

```json
{
  "access_token": "…",
  "token_type": "Bearer",
  "expires_in": 300,
  "refresh_token": "…",
  "scope": "read",
  "operator_id": "op_3H8…",
  "operator_name": "<the operator's seeded name>"
}
```

| Field | Rules |
|---|---|
| `operator_id` | The operator the grant belongs to; the same value as webhook envelopes' `operator_id` |
| `operator_name` | The operator's display name (synthetic seed data) |

## Compatibility

Additive. Existing clients that ignore unknown fields are unaffected. Feature 001's
`TokenResponse` schema, its token request spec, and `bin/connect_operator` (new, research R17)
are updated in the same change.

## Why

Webhook envelopes identify the operator by `operator_id`, but nothing in the OAuth exchange
did, so a subscriber could not tell which connection an event belongs to. Real platforms
return the account in the token response or a `whoami` call; the token response is the smaller
change.
