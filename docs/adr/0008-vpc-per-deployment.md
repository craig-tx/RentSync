# ADR-0008: One VPC per deployment, each environment peered only with shared

- **Status:** Accepted. Supersedes the "one VPC" decision in ADR-0005; the rest of ADR-0005
  stands.
- **Date:** 2026-10-25
- **Feature:** 002-aws-deployment (spec Session 2026-10-25, FR-007, FR-011; research R3, R8, R17)

## Context

ADR-0005 put every deployment in one VPC owned by `shared-us`, as the feature brief asked. A
staging host and a production host in the same network invite an obvious question in review:
what stops staging from reaching production? Security groups did stop it, but network
separation is the expected answer, and it costs nothing here because nothing had been applied
yet.

The real production answer goes further: the **Multi-Account Strategy via AWS Organizations**,
with a separate AWS account per environment. It gives hard blast-radius, IAM and billing
isolation, with service control policies over all of it. It also needs an Organization, a
landing zone, cross-account roles for HCP Terraform and GitHub, and cross-account telemetry.
That is far more setup and operation than a portfolio demo warrants. VPC isolation inside one
account is the step this demo takes instead.

## Decision

- **Every deployment owns its VPC**, built by the `modules/network` module. Each VPC has one
  public subnet, an internet gateway and a route table. The ranges are:

  | Deployment | VPC | Subnet | Host |
  |---|---|---|---|
  | `shared-us` | `10.40.0.0/16` | `10.40.1.0/24` | telemetry `10.40.1.10` |
  | `dev-staging` | `10.41.0.0/16` | `10.41.1.0/24` | `10.41.1.20` |
  | `prod-us` | `10.42.0.0/16` | `10.42.1.0/24` | `10.42.1.30` |

  A side-by-side deployment picks the next free `/16`, for example `pr-42` at `10.43.0.0/16`.
- **Each environment peers only with the shared VPC.** The environment root creates the peering
  connection (same account and region, so it accepts itself), its own route to the shared range,
  and the return route in the shared route table. Environment VPCs are never peered with each
  other, so staging and production have no route between them.
- **Telemetry stays on the private AWS network.** Each environment adds one standalone rule to
  the telemetry security group, admitting TCP 5080 from its own subnet. That subnet holds only
  its host. The shared `otlp-client` security group is gone, because security groups can't be
  attached across VPCs.
- **No inline routes or rules.** Route tables and security groups use standalone `aws_route` and
  rule resources only. An environment writes into resources the shared deployment owns. Inline
  blocks are authoritative, so the next shared apply would silently delete the environment's
  route or rule. `infra/terraform/check_prevent_destroy.sh` fails CI on any inline block.
- **All deployments stay in one availability zone,** taken from the shared deployment.
  Peering traffic within a zone is free, and hosts and data volumes are zonal.

## Alternatives considered

- **Shared telemetry inside the staging VPC, with production peered to it.** One peering
  connection instead of two. But production's telemetry would depend on staging's network, and
  rebuilding staging could cut production off. It also breaks the DeploymentId rule that every
  deployment owns its resources.
- **Transit Gateway:** about $36 a month per attached VPC, which breaks the cost ceiling
  (SC-009).
- **PrivateLink for OTLP:** about $20 a month or more, for an endpoint and a load balancer.
- **OTLP over the public internet, through the telemetry host's Caddy:** free, but it exposes
  ingest publicly with the OpenObserve root credentials.
- **Separate AWS accounts per environment** (Multi-Account Strategy via AWS Organizations):
  the production answer, kept as the documented next step in
  `docs/deploy/production-differences.md`.

## Consequences

- **No added cost.** VPCs, internet gateways and same-zone peering traffic are free.
- **Staging and production are separated at the network layer,** not just by security groups.
  A compromised staging host has no route to production.
- **An environment workspace writes two resources into the shared deployment's network:** a
  return route and a security group rule. Both belong to the environment's own state, so they
  are created and destroyed with it, and adding a deployment never edits shared code.
- **Each environment needs its own non-overlapping range,** set by `bootstrap-hcp.rb`. AWS
  rejects a peering between overlapping ranges, so a clash fails the apply rather than
  misrouting traffic.
- **Revisit** when the project moves to separate accounts. The per-deployment network module
  carries over, and only the peering becomes cross-account.
