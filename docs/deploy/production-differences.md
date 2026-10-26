# How a real production deployment would differ

This deployment is a cost-conscious demonstration (about $55 a month; research R5). It is
**not** production-ready (constitution §Scope). Each row compares a deliberate demo choice with
what a real production design would use, and says why the demo differs (FR-036). The overall
decisions are ADR-0005 and ADR-0008.

## Architecture

| Demo choice | Real production | Why the demo differs |
|---|---|---|
| **VPC isolation in one AWS account**: every deployment owns its VPC, and each environment is peered only with the shared telemetry VPC, so staging and production have no route to each other (ADR-0008) | The gold standard, the **Multi-Account Strategy via AWS Organizations**: a separate AWS account per environment, governed by service control policies | Separate accounts give hard blast-radius, IAM and billing isolation that one account can't. They also need an Organization, a landing zone, cross-account roles for HCP Terraform and GitHub, and cross-account telemetry, which is more than a portfolio demo warrants. For this demo, we chose VPC isolation: free, and it separates staging from production at the network layer. DeploymentId naming, per-deployment IAM roles and SSM paths add logical isolation. |
| **One EC2 host per deployment**, Docker Compose, in a single availability zone | **ECS Fargate** services across at least two availability zones, with autoscaling | Fargate removes host management and survives an availability-zone loss, but costs several times more for always-on tasks. The services are already stateless (constitution X), so the move is configuration, not code. |
| **Postgres and Redis in containers** on the host, with an EBS volume and daily snapshots | **RDS for PostgreSQL** (Multi-AZ, point-in-time recovery) and **ElastiCache** | RDS starts at about $14 per environment per month, and ElastiCache at about $6–9.50; both were priced and rejected (spec Clarifications). Snapshots bound data loss at 24 hours, where point-in-time recovery would bound it at minutes. |
| **Caddy on the host** terminates TLS with Let's Encrypt | **Application Load Balancer** with **ACM** certificates, and a WAF | An ALB costs about $16 or more per month per environment. Caddy gives automatic, renewing, publicly trusted TLS for free. |
| **Public subnet**; hosts have public IPs, with only 80 and 443 open | **Private subnets** for compute and data, **NAT gateways** for egress, and only the load balancer public | A NAT gateway costs about $33 per month per availability zone, which would break the ceiling on its own. Security groups admit only HTTP and HTTPS, and there is no SSH. |
| **DNS records created by hand** at the DNS provider | **Route 53** hosted zone managed as code, with health-checked records | The spec places DNS out of scope (FR-021). Elastic IPs make the records permanent, so manual records rarely change. |
| **One shared telemetry host** (OpenObserve plus Postgres on one EC2 instance) | A **managed or highly available observability stack**: OpenObserve HA or cloud, or CloudWatch with Managed Grafana and Prometheus | A single host is a single point of failure for telemetry. The services keep working without it (US3 AC4), and its data survives host replacement. |

## Security and operations

| Demo choice | Real production | Why the demo differs |
|---|---|---|
| **One HCP Terraform role** (`rentsync-hcp-terraform`) for all workspaces, with broad EC2 permissions in-region | **Separate plan and apply roles per workspace**, permission boundaries, and a narrow, reviewed policy | It keeps the hand-done bootstrap under an hour (FR-006). IAM actions are limited to `rentsync-*` names. |
| **Collectors use the OpenObserve root credentials** to ingest | **Per-environment ingest-only service accounts** | It avoids creating accounts through the API at bring-up. |
| **OTLP over plain HTTP on the private AWS network** (port 5080, over each environment's peering connection, admitted only from that environment's subnet) | **TLS on the ingest path**, or PrivateLink | The traffic never crosses the public internet, and the security group limits who can reach it. |
| **Single availability zone** for every host and volume | **Multi-AZ** for every tier | EBS volumes are zonal, and one zone keeps the host and its volume together. |
| **Releases by SSM Run Command** to one host, with a self-rollback (ADR-0006) | **Rolling or blue/green deploys** with load-balancer health checks and deployment circuit breakers | One host per environment has nothing to roll across. The script still stops and reverts on a failed health check. |
| **Secrets in SSM Parameter Store**, rotated by hand (ADR-0007) | **Secrets Manager with automatic rotation** | Secrets Manager costs $0.40 per secret per month and needs rotation Lambdas. Write-only arguments already keep secrets out of state. |

## Security monitoring and operations

| Demo choice | Real production | Why the demo differs |
|---|---|---|
| **No posture management or threat detection.** Security relies on the controls in code: OIDC instead of keys, no SSH, IMDSv2, encryption, least-privilege bootstrap roles, CI scanning | A **Cloud Security Posture Management (CSPM)** solution, such as **Orca Security**, continuously scanning every account for misconfigurations, vulnerabilities, exposed secrets and risky attack paths. Alongside it, AWS-native **GuardDuty** (threat detection), **Security Hub** (findings and benchmark checks) and **AWS Config** (configuration history and rules), aggregated across the Organization | A CSPM is a commercial product priced per workload. GuardDuty, Security Hub and Config each add a few to tens of dollars a month. Together they would exceed the demo's ceiling, and they report against a live estate that this demo keeps deliberately small. |
| **CloudTrail and VPC Flow Logs in a bucket in the same account**, kept 90 days, deleted with the shared deployment | An **organization trail** and Flow Logs delivered to a dedicated **log-archive account**, with S3 Object Lock, longer retention, and a SIEM or Athena for queries | A separate log-archive account belongs to the Multi-Account Strategy (see Architecture). The same-account bucket still records every API call and every VPC's traffic, at storage cost only. |
| **Outbound traffic unrestricted** from hosts (security groups allow all egress) | **Egress limited** to what each service needs (HTTPS, DNS, NTP, OTLP), through VPC endpoints for AWS services and an egress firewall | Hosts need HTTPS to ECR, SSM, Let's Encrypt and the Docker registries. Tight egress without VPC endpoints is brittle, and the endpoints cost about $7 a month each. |
| **OS patching by monthly AMI replacement** (runbook §Monthly OS patching), applied by hand | **Automated patching**: a pipeline that bakes and rolls out new images, or SSM Patch Manager with maintenance windows, plus vulnerability scanning of the running hosts (for example Amazon Inspector) | Replacement keeps hosts immutable and exercises recovery. Automation and Inspector add cost and moving parts a demo doesn't need. |
| **Dependency and code scanning in CI**: Dependabot, `bundle-audit`, CodeQL, Trivy for Terraform | The same, plus **container image scanning on every build**, signed images and admission policies | ECR already scans each pushed image (scan on push). Signing and admission control need a cluster to enforce them. |
