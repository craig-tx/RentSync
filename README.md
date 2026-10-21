# RentSync

A rent-payment sync and reporting pipeline for single-family rental operators, built with spec-driven development ([GitHub Spec Kit](https://github.com/github/spec-kit)). The project constitution is in [`.specify/memory/constitution.md`](.specify/memory/constitution.md), and feature specs are in [`specs/`](specs/).

## Mock PMS

A simulated property management system that RentSync connects to. It offers OAuth 2.0, a paginated read API, signed webhooks, per-client rate limits, and reproducible chaos (duplicates, reordering, delays, malformed bodies, injected 500s), so that RentSync's resilience can be demonstrated.

```bash
cp .env.example .env
docker compose up -d postgres redis mock_pms mock_pms_worker otel-collector openobserve
docker compose exec mock_pms bundle exec bin/setup
curl -s localhost:4001/healthz
```

See [`mock_pms/README.md`](mock_pms/README.md) for details and [`specs/001-mock-pms/quickstart.md`](specs/001-mock-pms/quickstart.md) for the full validation walkthrough.
