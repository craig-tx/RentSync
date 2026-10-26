# Feature Specification: AWS Deployment of the Mock PMS

**Feature Branch**: `002-aws-deployment`

**Created**: 2026-10-21

**Status**: Draft

**Input**: User description: "Deploy the mock PMS (feature 001) to AWS, driven by HashiCorp Terraform Cloud (HCP Terraform), with real applied infrastructure rather than plan-only. This is a cost-conscious demo deployment, and the docs must state clearly how a true production setup would differ (ECS Fargate, NAT gateways, RDS, ElastiCache, a load balancer, and separate VPCs or AWS accounts per environment). Requirements:
(1) A single AWS VPC holds everything; document that real production would not share one VPC.
(2) Two environments, staging and production, each on its own Linux EC2 instance with a public IP (Elastic IP). Each instance runs the mock PMS stack in Docker containers: Caddy for TLS termination, the mock PMS web service and delivery worker, Postgres, Redis, and the OpenTelemetry Collector. Only Caddy's ports (80/443) are exposed by security groups; no SSH.
(3) A single, shared OpenObserve instance on its own small EC2, running OpenObserve in Docker with Postgres in a container as its metadata store; every environment sends telemetry there; its UI is served through Caddy over TLS.
(4) The domain is rentsync.org, registered at NameCheap; DNS records are created by hand at NameCheap and point at the instances' Elastic IPs; Terraform does not manage DNS.
(5) Secrets (admin token, OpenObserve credentials, database passwords, etc.) come from Terraform Cloud's stored sensitive variables, the usual Terraform Cloud/AWS mechanism, and never live in the repo.
(6) Terraform Cloud authenticates to AWS without long-lived keys if possible.
(7) Operators must be able to deploy a new version of the mock PMS to staging and then production, verify each environment is healthy, and recover an instance without losing data.
The mock PMS must be fully deployed and working on both environments, verified end to end, before any further application features are built."

## Overview

This feature takes the mock PMS from feature 001, which today runs only on a developer's machine, and runs it on the public internet as two independent environments, **staging** and **production**. A single shared telemetry backend serves both. All infrastructure is declared as code and applied from a hosted infrastructure-as-code service (HCP Terraform). Secrets live only in that service and in the AWS account.

This is a **cost-conscious demonstration deployment**. Every place where it deliberately differs from a real production design is documented next to what a production design would use. From this feature on, RentSync features (002+ in the kickoff roadmap, now 003+) have a real, reachable PMS to integrate with.

Its users are:

- **Operator**: the project owner who provisions infrastructure, manages secrets, releases versions, and recovers instances.
- **Integration client**: RentSync services and any external tester. They reach the deployed mock PMS over HTTPS exactly as they reached it locally.
- **Reviewer**: a hiring reviewer or other reader. They inspect the live endpoints, the telemetry, and the documentation of the trade-offs.

## Clarifications

### Session 2026-10-21

- Q: How is each standalone deployment identified, and what derives from that identifier? → A: Every deployment has a DeploymentId (constitution v1.2.0, Principle VI). Production is `prod-us`, staging is `dev-staging`, and the shared telemetry deployment is `shared-us`. Every name the deployment owns derives from it: AWS resource names, IAM roles, parameter paths and database names. It is also the `DeploymentId` tag on every AWS resource and the `deployment.id` attribute on all telemetry. Deployments must be able to run side by side in the same AWS account.
- Q: Should the cache use a managed service (ElastiCache) instead of a container? → A: No. It is too expensive for the cost ceiling, so Redis stays a container on each environment host.

### Session 2026-10-25

- Q: Is the deployment tied to one operator's domain and accounts? → A: No. The domain, DNS provider, AWS account, AWS region and zone, HCP Terraform organization, GitHub repository and contact emails are per-operator **deployment settings**. `bootstrap-init.sh` asks for them and writes them to a gitignored file that the other bootstrap scripts read; the repository holds only placeholders. Input (4) describes the reference deployment: `rentsync.org`, with DNS at NameCheap.
- Q: Should staging and production share one VPC, as input (1) asks? → A: No. Every deployment owns its VPC: `shared-us`, `dev-staging` and `prod-us` each have one, and each environment VPC is peered only with the shared telemetry VPC, so staging and production have no route to each other (ADR-0008). Telemetry crosses the peering connections on the private AWS network. This supersedes input (1). For this portfolio demo we choose VPC isolation; a true production environment would use the gold standard, the **Multi-Account Strategy via AWS Organizations**, with a separate AWS account per environment.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Provision both environments and shared telemetry from code (Priority: P1)

The operator starts from an empty AWS account and an HCP Terraform organization. They configure the workspaces, store the secrets as sensitive variables, and apply. The run creates one network, one host for each environment, and one host for telemetry, each with a fixed public address. The operator adds the DNS records at the registrar, and the hosts come up serving their services over HTTPS.

**Why this priority**: Nothing else in this feature, and no later feature that integrates against a deployed PMS, can happen until the infrastructure exists.

**Independent Test**: From an AWS account with none of the project's resources, follow the deployment runbook to an applied state. Check that the three hosts exist, each with a stable public address. Scan each address from outside and find only ports 80 and 443 open. Confirm that no cloud access keys and no secret values appear in the repository or the plan output.

**Acceptance Scenarios**:

1. **Given** an empty AWS account, an HCP Terraform organization, and the documented sensitive variables, **When** the operator applies each workspace, **Then** one network, a staging host, a production host and a telemetry host exist, and each host has a fixed public IP address.
2. **Given** applied infrastructure, **When** each host's public address is port-scanned from the internet, **Then** only TCP 80 and 443 respond. Remote shell (SSH) is not reachable.
3. **Given** the operator needs a shell on a host, **When** they use the documented administrative access path, **Then** they get one without any inbound port being opened.
4. **Given** the HCP Terraform workspaces, **When** a plan or apply runs, **Then** it authenticates to AWS without a stored long-lived access key, and sensitive values are masked in run output.
5. **Given** the repository, **When** it is scanned for secrets, **Then** no secret values are found. Only variable names and example placeholders appear.

---

### User Story 2 - The mock PMS works end to end on staging and production (Priority: P1)

An integration client uses the deployed mock PMS just as it used the local one: it registers, completes the OAuth approval, pages through data, receives signed webhooks, hits the rate limit, and observes chaos when it is turned on. This works on both `https://pms-staging.<domain>` and `https://pms.<domain>`.

**Why this priority**: The whole point of this feature is a real, reachable PMS. Infrastructure without a working service delivers nothing.

**Independent Test**: Run the feature 001 validation steps (quickstart §3–§9) against each environment's public URL rather than localhost. Every step passes.

**Acceptance Scenarios**:

1. **Given** DNS records pointing at the hosts, **When** a client requests an environment's hostname over HTTPS, **Then** it gets a valid, publicly trusted certificate for that hostname, and plain HTTP redirects to HTTPS.
2. **Given** a deployed environment, **When** a client follows the OAuth flow (register through the admin API, approve as a seeded operator, exchange the code), **Then** it receives working tokens and can page through that operator's data, as in feature 001 US1.
3. **Given** a client with a public HTTPS webhook receiver, **When** a scenario runs on an environment, **Then** the client receives signed webhooks that verify with its signing secret, as in feature 001 US2.
4. **Given** each environment, **When** the rate-limit, chaos, replay and reset checks from the feature 001 quickstart run against it, **Then** they behave as they did locally.
5. **Given** staging and production, **When** a client is registered on one, **Then** it does not exist on the other. The environments share no application data.

---

### User Story 3 - See both environments' telemetry in one place (Priority: P2)

The operator opens `https://telemetry.<domain>`, signs in, and sees logs and metrics from both environments. Each record is labelled with its environment, so the operator can filter to one environment or follow one request across services by its correlation ID.

**Why this priority**: The constitution requires observability everywhere. A single shared backend keeps this affordable, and diagnosing anything on the deployed environments depends on it.

**Independent Test**: Trigger a scenario on staging and on production. Within one minute, find each scenario's log lines and metrics in the telemetry UI, separated by environment. Confirm that the telemetry UI is reachable only over HTTPS and only after sign-in.

**Acceptance Scenarios**:

1. **Given** both environments running, **When** the operator filters telemetry by environment, **Then** they see only that environment's logs and metrics, labelled `staging` or `production`.
2. **Given** a scenario run on production, **When** the operator searches its correlation ID, **Then** the web and worker log lines for that run appear together.
3. **Given** the telemetry host, **When** an anonymous visitor opens its URL, **Then** they reach a sign-in page over HTTPS and see no data.
4. **Given** the telemetry host is down, **When** clients use either environment, **Then** the mock PMS keeps serving requests and delivering webhooks. Telemetry resumes once the host is back.
5. **Given** the telemetry ingestion path, **When** the network rules are inspected, **Then** telemetry from the environment hosts travels inside the private network, not over the public internet.

---

### User Story 4 - Release a new version to staging, then production (Priority: P2)

The operator merges a change to the mock PMS. The new version reaches staging automatically or with one action. The operator verifies staging is healthy and then promotes the same version to production with an explicit approval. If production misbehaves, the operator rolls back to the previous version.

**Why this priority**: The environments are only useful if they can be kept current safely. Promoting the same build through staging to production is the core release discipline this project demonstrates.

**Independent Test**: Make a visible change, such as the reported service version. Release it to staging and confirm it there while production still reports the old version. Approve the promotion and confirm production reports the new version. Roll production back and confirm it reports the old version again.

**Acceptance Scenarios**:

1. **Given** a change merged to the main branch, **When** the release process runs, **Then** staging runs the new version, identified by the same build identifier in its health output and its telemetry.
2. **Given** a version running on staging, **When** the operator approves promotion, **Then** production runs exactly that build. Nothing is rebuilt between staging and production.
3. **Given** a release in progress, **When** the new version fails its health check, **Then** the release stops, the environment keeps or returns to its previous working version, and the operator is told.
4. **Given** production on version N, **When** the operator rolls back, **Then** production runs version N−1, and its data is unchanged.
5. **Given** a release, **When** it completes, **Then** existing data (clients, grants, events, deliveries) is preserved and pending webhook deliveries continue.

---

### User Story 5 - Recover an instance without losing data (Priority: P3)

A host is lost or must be replaced: it is terminated by accident, its disk image is upgraded, or its instance type changes. The operator recreates it from code. It comes back at the same public address with its data intact, up to the most recent backup point at the worst.

**Why this priority**: Recovery is what turns "it's running" into "it's operable". It is lower priority only because it builds on stories 1–4.

**Independent Test**: Record some data on staging (a client, a grant, a few events). Replace the staging host through the documented procedure. Confirm that it returns at the same address with a valid certificate and the same data. Then restore from a backup into a fresh host and confirm the data as of that backup.

**Acceptance Scenarios**:

1. **Given** a running environment with data, **When** its host is replaced through the documented procedure, **Then** the new host has the same public address and the same data, and no DNS change is needed.
2. **Given** an environment, **When** the backup schedule runs, **Then** a restorable backup of its data exists at least once every 24 hours, and backups older than the retention period are removed automatically.
3. **Given** a backup, **When** the operator restores it into a replacement host, **Then** the environment serves the data as of that backup.
4. **Given** the infrastructure code, **When** an operator plans a change that would destroy an environment's data storage, **Then** the run refuses or requires an explicit, deliberate override.
5. **Given** a host restart (reboot or stop/start), **When** it comes back, **Then** all services start on their own and the environment passes its health check without manual steps.

---

### Edge Cases

- **DNS not yet pointed:** before the DNS records resolve to a host, that host cannot obtain a certificate. It must keep retrying without hitting the certificate authority's rate limits, and become healthy once DNS resolves.
- **Certificate renewal:** certificates renew automatically before they expire, with no operator action and no downtime.
- **Secrets rotation:** after the operator changes a sensitive variable (for example the admin token), the next apply and release take the new value. The old value stops working, and no secret appears in plan or apply logs.
- **Partial apply failure:** a failed run leaves the infrastructure in a state that a re-run converges, without duplicate resources or orphaned public addresses.
- **Production change without approval:** production infrastructure and releases never apply without an explicit human approval. Staging may apply automatically.
- **Drift:** a manual change in the cloud console shows up as drift on the next plan.
- **Disk full on a host:** log and container growth is bounded, through log rotation and pruning of old images, so a host does not fill its disk over weeks of uptime.
- **Telemetry host replaced:** existing telemetry data survives, or the loss is bounded and documented. Environments reconnect without being reconfigured.
- **Clock and timezone:** hosts keep accurate time, because webhook signatures, tokens and backups depend on it.
- **Cost runaway:** an unexpected bill shows up as a budget alert before it grows. Nothing scales without bound.
- **Instance replaced while webhooks are pending:** pending deliveries resume after recovery. At-least-once delivery holds across the replacement.
- **Side-by-side deployment:** a further deployment with a new DeploymentId, such as `pr-42`, can be planned in the same AWS account. It does not collide in name, parameter path, address or database name with `prod-us`, `dev-staging` or `shared-us`, and it needs no change to their code or variables.
- **Public admin API:** the mock PMS admin endpoints are reachable on the internet. They stay protected by the admin token, which is strong, generated per environment, and never the example value.

## Requirements *(mandatory)*

### Functional Requirements

**Infrastructure as code and workflow**

- **FR-001**: All cloud infrastructure for this feature MUST be declared as code in the repository and created only by applying that code through HCP Terraform (Terraform Cloud). Manual creation in the cloud console is not permitted, except for the documented one-time bootstrap.
- **FR-002**: There MUST be separate HCP Terraform workspaces for staging, production and shared telemetry, so that each can be planned and applied independently. Staging and production MUST use the same infrastructure definitions and differ only by input variables.
- **FR-003**: Production applies MUST require an explicit human approval. Staging MAY apply automatically from the main branch.
- **FR-004**: HCP Terraform MUST authenticate to AWS with short-lived credentials obtained through workload identity (dynamic provider credentials). No long-lived AWS access key is stored in HCP Terraform or in the repository.
- **FR-005**: The operator MUST be able to see drift between the code and the real infrastructure through a plan.
- **FR-006**: A one-time bootstrap MUST be documented: the trust relationship between HCP Terraform and AWS, the workspace creation, and the registration of sensitive variables. The bootstrap MUST take less than one hour by following the runbook.

**Network and hosts**

- **FR-007**: Each deployment MUST have its own virtual network (VPC). Each environment's VPC MUST be connected only to the shared deployment's VPC, never to another environment's, so staging and production have no network path to each other. The documentation MUST state that real production would use the Multi-Account Strategy via AWS Organizations, with a separate AWS account per environment (Session 2026-10-25).
- **FR-008**: The three initial deployments MUST have exactly three hosts: staging (`dev-staging`), production (`prod-us`), and shared telemetry (`shared-us`). Side-by-side deployments (FR-042) add their own. Each MUST have a fixed public IP address (Elastic IP) that survives the host being replaced.
- **FR-009**: Inbound access from the internet MUST be limited to TCP 80 and 443 on every host. No SSH or other administrative port may be open to the internet.
- **FR-010**: Operators MUST have a documented administrative shell path to each host that needs no inbound port.
- **FR-011**: The telemetry ingestion port MUST accept connections only from the environment hosts, over the private AWS network. It MUST NOT be reachable from the internet.
- **FR-012**: Hosts MUST keep accurate time, start every service automatically on boot, rotate logs, and prune unused container images, so they stay healthy without operator attention.

**Services on each environment host**

- **FR-013**: Each environment host MUST run the complete mock PMS stack from feature 001 as containers: the web service, the delivery worker, its database, its cache, and the telemetry collector. A TLS-terminating reverse proxy MUST sit in front of the web service.
- **FR-014**: Each environment MUST be reachable at its own hostname under the deployment's domain over HTTPS, with a publicly trusted certificate obtained and renewed automatically. Plain HTTP MUST redirect to HTTPS.
- **FR-015**: Staging and production MUST share no application data. Each MUST have its own database, cache, clients, grants and secrets.
- **FR-016**: Each environment's telemetry MUST carry `deployment.environment` set to `staging` or `production`, and `deployment.id` set to its DeploymentId (FR-038). It MUST be sent to the shared telemetry host. All of feature 001's telemetry requirements (Constitution VI) MUST continue to hold.
- **FR-017**: Every feature 001 behavior MUST work identically on both environments. The feature 001 quickstart checks (§3–§9) are the acceptance test, run against the public URLs.

**Shared telemetry host**

- **FR-018**: The telemetry host MUST run the telemetry backend (OpenObserve) with its own metadata database, both as containers. A TLS-terminating reverse proxy MUST serve its UI at its own hostname under the deployment's domain.
- **FR-019**: The telemetry UI MUST require sign-in, and its credentials MUST come from the secret store.
- **FR-020**: Telemetry data MUST be stored on durable storage that survives the host being replaced, as FR-031 specifies.

**DNS**

- **FR-021**: DNS records MUST NOT be managed by the infrastructure code. They are created by hand at the operator's DNS provider. The runbook MUST list the exact records (hostname to public IP), which the infrastructure code outputs after apply.

**Secrets**

- **FR-022**: Every secret MUST originate as an HCP Terraform sensitive variable, or be generated by the infrastructure code. That covers each environment's admin token, the database passwords, the telemetry credentials, and the client and telemetry auth used between hosts.
- **FR-023**: Secrets MUST be delivered to the hosts through the cloud provider's managed secret or parameter store. They MUST be encrypted at rest and readable only by the host that needs them.
- **FR-024**: Secret values MUST NOT appear in the repository, in plan or apply output, or in host logs. Where the tooling supports it, they MUST also be kept out of infrastructure state.
- **FR-025**: The admin token and database passwords MUST be different for staging and production, and MUST NOT be the example values from `.env.example`.

**Releases**

- **FR-026**: A release MUST build one immutable, versioned image of the mock PMS, identified by its source commit, and store it in a private container registry.
- **FR-027**: A release MUST deploy that image to staging first. Promotion to production MUST deploy the same image, not a rebuild, and MUST require explicit approval.
- **FR-028**: After deploying, the release MUST check the environment's health endpoint and the reported service version. If the check fails, the release stops and the environment keeps or returns to its previous working version.
- **FR-029**: The operator MUST be able to roll an environment back to the previously deployed version in one documented action.
- **FR-030**: Releases MUST preserve all data and MUST NOT drop pending webhook deliveries, because the outbox survives a restart.

**Durability and recovery**

- **FR-031**: Each environment's database and the telemetry host's data MUST live on durable storage that is separate from the host's root disk, and that storage MUST survive the host being replaced.
- **FR-032**: Automated backups of every durable data store MUST run at least daily, with a documented retention (default 7 daily backups).
- **FR-033**: The documented recovery procedures MUST cover:
  - replacing a host while keeping its data;
  - restoring an environment from a backup;
  - rotating a secret.
- **FR-034**: The infrastructure code MUST protect durable data storage from accidental destruction. Deleting it requires a deliberate, documented override.

**Cost and documentation**

- **FR-035**: The deployment MUST include a monthly budget with alerts to the operator. It MUST send a warning at 80% and an alert at 100%.
- **FR-036**: The documentation MUST include a "real production would differ" section comparing each demo choice with its production equivalent:
  - VPC isolation in one account, compared with separate accounts per environment (Multi-Account Strategy via AWS Organizations);
  - a single EC2 host per environment, compared with ECS Fargate across availability zones;
  - containerized Postgres and Redis, compared with RDS and ElastiCache;
  - a Caddy proxy on the host, compared with a load balancer with managed certificates;
  - a public subnet, compared with private subnets and NAT gateways;
  - manual DNS, compared with managed DNS;
  - a shared telemetry host, compared with a managed or highly available observability stack.

  For each pair it MUST give the reason.
- **FR-037**: A runbook MUST cover the deployment process and these operations:
  - bootstrap;
  - DNS setup;
  - first deploy;
  - release and promotion;
  - rollback;
  - host replacement;
  - backup restore;
  - secret rotation;
  - replaying failed webhooks on a deployed environment;
  - tearing everything down.

**Deployment identity (constitution Principle VI, v1.2.0)**

- **FR-038**: Each standalone deployment MUST have a DeploymentId, and the infrastructure code MUST validate its format. The values are:
  - `prod-us` for the production environment;
  - `dev-staging` for the staging environment;
  - `shared-us` for the shared telemetry deployment, which also owns the network and the image registry.
- **FR-039**: Every name, path and identifier a deployment owns MUST be derived from its DeploymentId or supplied as that deployment's configuration. Nothing may be hard-coded. This covers:
  - AWS resource names;
  - IAM roles;
  - secret and parameter paths;
  - database names, with hyphens written as underscores, e.g. `mock_pms_prod_us`;
  - private addresses.
- **FR-040**: Every AWS resource MUST carry a `DeploymentId` tag with its deployment's value, applied by default to everything the infrastructure code creates.
- **FR-041**: The mock PMS MUST emit `deployment.id` on all logs and metrics, read from configuration. Local development uses a value such as `local-<name>`. This brings the feature 001 service into compliance with constitution v1.2.0.
- **FR-042**: A new deployment MUST be addable side by side in the same AWS account by supplying a new DeploymentId and its configuration only. The code of existing deployments MUST NOT change.

### Key Entities

- **Deployment**: one long-lived, standalone stack instance identified by its DeploymentId (`prod-us`, `dev-staging`, `shared-us`). It is not a release: the build that is running is identified separately by its version. An environment is served by exactly one deployment.
- **Environment**: staging or production. It has a hostname, a host, durable data storage, a secret set, a deployed version, and telemetry labelled with its name.
- **Host**: a single virtual machine. It has a role (staging, production or telemetry), a fixed public address, a root disk, attached durable data storage, and an identity that lets it read only its own secrets.
- **Workspace**: an HCP Terraform workspace. It covers one scope (staging, production or telemetry) and has its own variables, sensitive values, run history, and approval policy.
- **Secret**: a named sensitive value. It belongs to one environment or to the shared telemetry host, is stored encrypted, and is delivered to the host that needs it.
- **Release**: an immutable image identified by its source commit. It records where it has been deployed and when, and whether it was promoted.
- **Backup**: a point-in-time copy of an environment's or the telemetry host's durable data, with a creation time and an expiry.
- **DNS record**: a hostname under the deployment's domain mapped to a host's public address. It is created by hand at the DNS provider from the infrastructure outputs.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Starting from an empty AWS account and a completed bootstrap, the operator reaches three healthy hosts serving HTTPS at their hostnames in under 60 minutes of elapsed time, following only the runbook. DNS propagation time is excluded.
- **SC-002**: 100% of the feature 001 quickstart checks (§3–§9) pass against both the staging and the production public URLs.
- **SC-003**: An external port scan of each public address finds exactly two open ports, 80 and 443.
- **SC-004**: A secret scan of the repository and of the HCP Terraform run logs finds zero secret values.
- **SC-005**: A merged change reaches staging and passes its health check within 15 minutes. Promoting it to production takes under 10 minutes after approval.
- **SC-006**: Rolling back production to the previous version takes under 10 minutes and changes no data.
- **SC-007**: Replacing a host returns it to healthy at the same address with all its data in under 30 minutes. Restoring from a backup loses at most 24 hours of data.
- **SC-008**: Logs and metrics from a scenario run on either environment appear in the shared telemetry UI within 60 seconds, labelled with the correct environment.
- **SC-009**: The steady-state cloud cost of all three hosts and their storage, addresses and backups stays under USD 60 per month. The budget alert fires before a month exceeds it.
- **SC-010**: Both environments remain healthy, with certificates renewed and disks below 80% full, through 30 days of unattended running.
- **SC-011**: A query for AWS resources in the AWS account finds zero project resources without a `DeploymentId` tag. A plan for a hypothetical fourth deployment shows no name or address collision with the existing three.

## Assumptions

- **Feature numbering:** this is feature 002. The kickoff roadmap's "connection and webhook ingestion" feature becomes 003, and later features shift by one. The kickoff's later infrastructure feature (formerly 007) extends this deployment to the other RentSync services.
- **Hostnames**, each an A record at the DNS provider pointing at that host's Elastic IP:
  - staging: `pms-staging.<domain>`;
  - production: `pms.<domain>`;
  - telemetry: `telemetry.<domain>`.
- **Deployment settings:** the domain, a single AWS account with its region and zone, the HCP Terraform organization and the GitHub repository are the operator's choice. They are set once in `.bootstrap/settings.env` (gitignored) and never committed (Session 2026-10-25). The reference deployment uses `rentsync.org` in `us-east-1`.
- **Host sizing:** small general-purpose instances are enough for the mock PMS at demo volumes. The exact instance types are a plan decision, within the SC-009 cost ceiling.
- **Managed cache rejected:** ElastiCache (about $6–9.50 per environment per month) was considered as the one managed service and rejected on cost. Redis stays a container on each environment host and is listed under FR-036.
- **Public subnet:** hosts sit in a public subnet with public addresses, so no NAT gateway is needed. That is deliberate and documented under FR-036.
- **Bootstrap (FR-006):** a **scripted, plan-by-default bootstrap** that the operator runs (AWS CloudShell for AWS, their own machine for HCP Terraform and GitHub); each script prints a plan and changes nothing until rerun with `--apply`. It creates:
  - the OIDC trust between HCP Terraform and AWS, with its IAM role;
  - the GitHub Actions role for pushing images;
  - the workspaces;
  - the sensitive variables.

  No AWS access keys are created, and none pass through chat or the repository. After the bootstrap, every change is made through HCP Terraform runs. The runbook also lists every non-secret value (AWS account ID, AWS region, HCP Terraform organization name, AWS IAM role ARNs) and where each one is entered.
- **Administrative access:** shell access uses the cloud provider's session-manager-style access, which needs no inbound port (FR-010).
- **Certificates** come from a free, public, automated certificate authority (Let's Encrypt, through the reverse proxy). Staging may use the certificate authority's own staging endpoint during first bring-up, to avoid rate limits.
- **CI:** the GitHub repository and its CI are already in place from feature 001. Releases extend that CI to build and push images. Plan and apply runs happen in HCP Terraform.
- **Backups:** volume snapshots taken by the cloud provider's lifecycle service are enough. Database-level dumps are optional.
- **Teardown:** the deployment can be torn down entirely, to stop costs, with the documented override for protected storage.
- **Out of scope:**
  - managed DNS;
  - multi-region or high-availability designs;
  - autoscaling;
  - a web application firewall;
  - deploying any RentSync service other than the mock PMS;
  - separate AWS accounts per environment.

  These are documented as production differences, not built.
- **Dependencies:**
  - feature 001, merged on `main`: the mock PMS, its image, Compose stack, Collector config and quickstart;
  - an HCP Terraform organization and an AWS account owned by the operator;
  - a domain whose DNS the operator controls.
