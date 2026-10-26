# ADR-0005: Demo AWS topology — one VPC, one EC2 host per deployment, named by DeploymentId

- **Status:** Accepted. Its "one VPC" decision is superseded by ADR-0008 (one VPC per deployment, each
  environment peered only with shared); everything else stands.
- **Date:** 2026-10-21
- **Feature:** 002-aws-deployment (research R1, R3–R7, R17)

## Context

Feature 002 puts the mock PMS on the public internet as two environments, staging and
production, sending telemetry to one shared OpenObserve. The brief is cost-conscious: under
USD 60 a month (SC-009), with real applied infrastructure rather than a plan-only demo.
Constitution v1.2.0 adds a DeploymentId that every deployment-owned name must derive from, so
that deployments can run side by side in one AWS account.

A conventional production design would cost far more than the ceiling. It would have ECS
Fargate across availability zones, an ALB, RDS, ElastiCache, NAT gateways, and separate
accounts per environment. ElastiCache alone was priced at about $6–9.50 per environment per
month, and was rejected.

## Decision

- **One VPC with one public subnet**, owned by the `shared-us` deployment. *Superseded by
  ADR-0008: every deployment now owns its VPC.* There is no NAT gateway: hosts have public IPs,
  and only TCP 80 and 443 are open.
- **One EC2 host per deployment** (`t4g.small`, Amazon Linux 2023 arm64, pinned AMI). Each host
  runs its whole stack in Docker Compose behind Caddy, which handles TLS. The stacks are:
  - environments: the mock PMS web service and worker, Postgres, Redis, and the Collector;
  - `shared-us`: OpenObserve with its Postgres.
- **Hosts are disposable; data is not.**
  - Each host's Elastic IP sits on a standalone network interface with a fixed private IP.
  - Its data lives on a separate encrypted EBS volume with `prevent_destroy` and daily DLM
    snapshots.
  - Replacing the instance keeps the public address, the private address, the data and the
    TLS certificates.
- **Shell access through SSM Session Manager**, with no SSH and no key pair.
- **Every deployment-owned name derives from its DeploymentId**: `rentsync-<id>-*` resources
  and roles, `/rentsync/<id>/` parameters, the `mock_pms_<id>` database, and the
  `rentsync-<id>` Compose project. Every resource carries a `DeploymentId` tag through provider
  `default_tags` (root volumes explicitly). The first three deployments are `shared-us`,
  `dev-staging` and `prod-us`.
- **Three HCP workspaces over two Terraform roots.** Staging and production run the same
  `environment` root with different variables.

## Alternatives considered

- **ECS Fargate with an ALB, RDS and ElastiCache**: the production answer, at roughly 3–4 times
  the cost. Recorded in `docs/deploy/production-differences.md`.
- **One host for both environments**: cheaper, but it breaks FR-015 (no shared application
  data) and makes a staging problem a production outage.
- **Naming resources by environment** (`rentsync-staging-*`): simpler, but a second staging-like
  stack would collide. That is what the DeploymentId rule exists to prevent.
- **Private subnets with NAT**: about $33 a month per NAT gateway, which breaks the ceiling on
  its own.

## Consequences

- The cost is about $55 a month, of which about $11 is public IPv4 charges (research R5).
- Each environment has a single point of failure. A host replacement takes minutes of
  downtime, and an availability-zone outage takes the deployment down. Both are acceptable for
  a demo, and stated.
- A side-by-side deployment (for example `pr-42`) needs a workspace, a GitHub Environment, one
  choice-list entry and an A record. No existing code, variable or IAM policy changes.
- Changing host configuration replaces the host. This is deliberate: it keeps hosts immutable,
  and it exercises the recovery path on every change.
- **Revisit** if the project needs high availability, or once the monthly ceiling allows
  managed data services.
