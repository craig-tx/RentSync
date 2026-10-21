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

## Deployment (AWS, feature 002)

The mock PMS runs on AWS as two independent deployments, plus one shared telemetry host, all applied from HCP Terraform. Each deployment is named by its DeploymentId (constitution Principle VI):

| DeploymentId | Serves | URL |
|---|---|---|
| `dev-staging` | staging | `https://pms-staging.rentsync.org` |
| `prod-us` | production | `https://pms.rentsync.org` |
| `shared-us` | network, image registry, OpenObserve | `https://telemetry.rentsync.org` (sign-in required) |

The URLs go live once the one-time bootstrap in the runbook is done. Merging to `main` releases to `dev-staging` automatically. The same image goes to `prod-us` only after an approval.

This is a **cost-conscious demo** (about $55 a month) and is not production-ready: one VPC, one EC2 host per deployment, and Postgres and Redis in containers. [`docs/deploy/production-differences.md`](docs/deploy/production-differences.md) compares each of those choices with what production would use, and why.

- Operator runbook (bootstrap, DNS, release, rollback, recovery, rotation, teardown): [`docs/deploy/runbook.md`](docs/deploy/runbook.md)
- Decisions: [ADR-0005 topology](docs/adr/0005-demo-aws-topology.md), [ADR-0006 releases](docs/adr/0006-releases-via-ssm.md), [ADR-0007 secrets](docs/adr/0007-secrets-ssm-write-only.md)
- Spec, plan and validation: [`specs/002-aws-deployment/`](specs/002-aws-deployment/)
