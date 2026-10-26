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

### Running the tests

The same commands work on Windows and macOS (constitution: Cross-platform development). Run them
from the repository root: in **Git Bash** on Windows, in **Terminal** on macOS. You need Docker
Desktop, plus Ruby 3+ and Terraform for the last two lines (see the runbook's §Bootstrap for how
to install them on each platform).

```bash
docker compose run --rm mock_pms bundle exec rspec   # the mock PMS (Compose starts Postgres and Redis)
bash infra/test/run.sh                               # host and bootstrap scripts, in a Linux container
ruby infra/bootstrap/test/bootstrap_hcp_test.rb      # HCP bootstrap, against a fake API
terraform -chdir=infra/terraform/shared test         # likewise environment, modules/host, modules/network (init -backend=false first)
```

`infra/test/run.sh` runs the shell tests inside a container because they exercise scripts that run
on Linux (the EC2 hosts and AWS CloudShell). Three checks run only in CI:
`infra/host/test/boot_volume_test.sh` and `infra/host/test/swap_test.sh`, which need a Linux
host with root, and the check that the bootstrap scripts refuse bash 3.2 and 4.3, which is a step
in `ci.yml`.

See [`mock_pms/README.md`](mock_pms/README.md) for details and [`specs/001-mock-pms/quickstart.md`](specs/001-mock-pms/quickstart.md) for the full validation walkthrough.

## Deployment (AWS, feature 002)

The mock PMS runs on AWS as two independent deployments, plus one shared telemetry host, all applied from HCP Terraform. Each deployment is named by its DeploymentId (constitution Principle VI):
The URLs below are the reference deployment, at `rentsync.org`. To deploy your own copy under your own domain and accounts, follow [`docs/deploy/runbook.md`](docs/deploy/runbook.md): its first step asks for your settings, and nothing operator-specific is committed.


| DeploymentId | Serves | URL |
|---|---|---|
| `dev-staging` | staging | `https://pms-staging.rentsync.org` |
| `prod-us` | production | `https://pms.rentsync.org` |
| `shared-us` | network, image registry, OpenObserve | `https://telemetry.rentsync.org` (sign-in required) |

The URLs go live once the one-time bootstrap in the runbook is done. Merging to `main` releases to `dev-staging` automatically. The same image goes to `prod-us` only after an approval.

This is a **cost-conscious demo** (about $55 a month) and is not production-ready: VPC isolation inside one AWS account (each deployment has its own VPC; production would use the Multi-Account Strategy via AWS Organizations, with a separate account per environment), one EC2 host per deployment, and Postgres and Redis in containers. [`docs/deploy/production-differences.md`](docs/deploy/production-differences.md) compares each of those choices with what production would use, and why.

- Operator runbook (bootstrap, DNS, release, rollback, recovery, rotation, teardown): [`docs/deploy/runbook.md`](docs/deploy/runbook.md)
- Decisions: [ADR-0005 topology](docs/adr/0005-demo-aws-topology.md), [ADR-0006 releases](docs/adr/0006-releases-via-ssm.md), [ADR-0007 secrets](docs/adr/0007-secrets-ssm-write-only.md)
- Spec, plan and validation: [`specs/002-aws-deployment/`](specs/002-aws-deployment/)
