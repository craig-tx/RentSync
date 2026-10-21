# RentSync deployment runbook

Operator procedures for the AWS deployment of the mock PMS (feature 002). Design and rationale:
[specs/002-aws-deployment/](../../specs/002-aws-deployment/). End-to-end validation:
[quickstart.md](../../specs/002-aws-deployment/quickstart.md).

Deployments (constitution Principle VI, DeploymentId):

| DeploymentId | Serves | HCP workspace | URL |
|---|---|---|---|
| `shared-us` | VPC, ECR, telemetry, backups, budget | `rentsync-shared-us` | `https://telemetry.rentsync.org` |
| `dev-staging` | staging | `rentsync-dev-staging` | `https://pms-staging.rentsync.org` |
| `prod-us` | production | `rentsync-prod-us` | `https://pms.rentsync.org` |

## Bootstrap

TBD (task T051).

## DNS

TBD (task T052).

## First deploy

TBD (task T063).

## Release and promotion

TBD (task T073).

## Rollback

TBD (task T073).

## Host replacement

TBD (task T078).

## Backup restore

TBD (task T079).

## Secret rotation

TBD (task T080).

## Replaying failed webhooks on a deployed environment

TBD (task T063).

## Adding a side-by-side deployment

TBD (task T081).

## Teardown

TBD (task T081).
