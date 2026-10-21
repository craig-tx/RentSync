# How a real production deployment would differ

This deployment is a cost-conscious demonstration (about $55 a month). It is **not**
production-ready (constitution §Scope). Each row below compares a deliberate demo choice with
what a real production design would use, and gives the reason for the difference (FR-036).

| Demo choice | Real production | Why the demo differs |
|---|---|---|
| One VPC for every deployment | Separate VPCs, normally separate AWS accounts, per environment | TBD (task T084) |
| One EC2 host per deployment | ECS Fargate services across availability zones | TBD (task T084) |
| Postgres and Redis in containers on the host | RDS and ElastiCache | TBD (task T084) |
| Caddy on the host for TLS | Application Load Balancer with ACM certificates | TBD (task T084) |
| Public subnet, public IPs | Private subnets with NAT gateways | TBD (task T084) |
| DNS records by hand at NameCheap | Route 53, managed as code | TBD (task T084) |
| One shared telemetry host | A managed or highly available observability stack | TBD (task T084) |
