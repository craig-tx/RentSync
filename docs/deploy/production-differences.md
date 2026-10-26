# How a real production deployment would differ

This deployment is a cost-conscious demonstration (about $55 a month; research R5). It is
**not** production-ready (constitution §Scope). Each row compares a deliberate demo choice with
what a real production design would use, and says why the demo differs (FR-036). The overall
decision is ADR-0005.

## Architecture

| Demo choice | Real production | Why the demo differs |
|---|---|---|
| **One VPC** shared by every deployment, in one AWS account | **Separate VPCs, normally separate AWS accounts** per environment (AWS Organizations, with SCPs) | Separate accounts give hard blast-radius and IAM isolation. Here, DeploymentId naming, per-deployment security groups and SSM paths give logical isolation at no extra cost. |
| **One EC2 host per deployment**, Docker Compose, in a single availability zone | **ECS Fargate** services across at least two availability zones, with autoscaling | Fargate removes host management and survives an availability-zone loss, but costs several times more for always-on tasks. The services are already stateless (constitution X), so the move is configuration, not code. |
| **Postgres and Redis in containers** on the host, with an EBS volume and daily snapshots | **RDS for PostgreSQL** (Multi-AZ, point-in-time recovery) and **ElastiCache** | RDS starts at about $14 per environment per month, and ElastiCache at about $6–9.50; both were priced and rejected (spec Clarifications). Snapshots bound data loss at 24 hours, where point-in-time recovery would bound it at minutes. |
| **Caddy on the host** terminates TLS with Let's Encrypt | **Application Load Balancer** with **ACM** certificates, and a WAF | An ALB costs about $16 or more per month per environment. Caddy gives automatic, renewing, publicly trusted TLS for free. |
| **Public subnet**; hosts have public IPs, with only 80 and 443 open | **Private subnets** for compute and data, **NAT gateways** for egress, and only the load balancer public | A NAT gateway costs about $33 per month per availability zone, which would break the ceiling on its own. Security groups admit only HTTP and HTTPS, and there is no SSH. |
| **DNS records created by hand** at NameCheap | **Route 53** hosted zone managed as code, with health-checked records | The spec places DNS out of scope (FR-021). Elastic IPs make the records permanent, so manual records rarely change. |
| **One shared telemetry host** (OpenObserve plus Postgres on one EC2 instance) | A **managed or highly available observability stack**: OpenObserve HA or cloud, or CloudWatch with Managed Grafana and Prometheus | A single host is a single point of failure for telemetry. The services keep working without it (US3 AC4), and its data survives host replacement. |

## Security and operations

| Demo choice | Real production | Why the demo differs |
|---|---|---|
| **One HCP Terraform role** (`rentsync-hcp-terraform`) for all workspaces, with broad EC2 permissions in-region | **Separate plan and apply roles per workspace**, permission boundaries, and a narrow, reviewed policy | It keeps the hand-done bootstrap under an hour (FR-006). IAM actions are limited to `rentsync-*` names. |
| **Collectors use the OpenObserve root credentials** to ingest | **Per-environment ingest-only service accounts** | It avoids creating accounts through the API at bring-up. |
| **OTLP over plain HTTP inside the VPC** (port 5080, admitted only from the OTLP-client security group) | **TLS on the ingest path**, or PrivateLink | The traffic never leaves the VPC, and the security group limits who can reach it. |
| **Single availability zone** for every host and volume | **Multi-AZ** for every tier | EBS volumes are zonal, and one zone keeps the host and its volume together. |
| **Releases by SSM Run Command** to one host, with a self-rollback (ADR-0006) | **Rolling or blue/green deploys** with load-balancer health checks and deployment circuit breakers | One host per environment has nothing to roll across. The script still stops and reverts on a failed health check. |
| **Secrets in SSM Parameter Store**, rotated by hand (ADR-0007) | **Secrets Manager with automatic rotation** | Secrets Manager costs $0.40 per secret per month and needs rotation Lambdas. Write-only arguments already keep secrets out of state. |
