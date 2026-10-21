# ADR-0006: Release outside Terraform — build once, deploy through SSM Run Command

- **Status:** Accepted
- **Date:** 2026-10-21
- **Feature:** 002-aws-deployment (research R9)

## Context

FR-026 to FR-030 ask for these release properties:

- one immutable image per commit;
- staging first, then an approved promotion of the same image to production;
- an automatic stop when a health check fails;
- a one-action rollback;
- no data loss.

The infrastructure is applied by HCP Terraform. Host configuration lives in cloud-init user
data, so changing it replaces the host.

## Decision

- **Terraform creates the place an image runs; it never chooses the image.** The deployed tag
  is runtime state, kept in the SSM parameters `/rentsync/<id>/image_tag` and
  `previous_image_tag`. Terraform creates both with `ignore_changes = [value]`.
- **GitHub Actions builds once.** It builds `linux/arm64` on a native runner, tags the image
  with the full commit SHA, and pushes it to ECR, where tags are immutable. An existing tag is
  skipped.
- **Deploys run `rentsync-deploy` on the host through SSM Run Command.** Commands target
  `tag:DeploymentId` and `tag:rentsync:deployable`. The release role may run commands only on
  instances with the second tag. `rentsync-deploy`:
  1. takes a lock;
  2. renders secrets from SSM into a tmpfs file;
  3. pulls the image;
  4. runs `bin/setup --deploy` (migrate, and seed only an empty database);
  5. runs `docker compose up -d`;
  6. waits until `/healthz` reports `ok`, the new `version` and its own `deployment_id`.

  On success, it records the tags. On failure, it brings the previous image back and exits
  non-zero, which turns the workflow red.
- **Promotion is the `prod-us` GitHub Environment's required reviewer.** `release.yml` deploys
  `dev-staging` automatically, then waits for that approval before deploying the same SHA.
- **Rollback is the Deploy workflow with `rollback`.** It swaps `image_tag` and
  `previous_image_tag`. **Reload** re-renders secrets after a rotation.
- **Migrations are expand-only within a release**, so version N−1 always runs against
  version N's schema.

## Alternatives considered

- **The image tag as a Terraform variable**: every release would be an HCP run, a user-data
  change could replace the host, and drift reports would be noisy. Rejected.
- **A pull agent on the host (Watchtower or similar)**: one more dependency, and "stop and roll
  back on a failed health check" becomes hard to express. Rejected.
- **CodeDeploy**: a new service and agent, more than one host per environment needs. Rejected.
- **SSH from CI**: needs an open port 22 and a stored key, which FR-009 and FR-004 forbid.

## Consequences

- A release never touches infrastructure, and infrastructure changes never change the
  running version. The two are reviewed separately: GitHub Environment approval for releases,
  HCP manual apply for production infrastructure.
- `rentsync-deploy` is the most important script on the host. `infra/host/test/deploy_test.sh`
  covers deploy, no-op, self-rollback, manual rollback, reload with nothing deployed, and bad
  input, using stub `docker` and `aws`.
- SSM Run Command output is truncated at 24,000 characters in the workflow log. That is enough
  for `rentsync-deploy`, which prints a few lines.
- **Revisit** if the deployment moves to ECS. Rolling updates and circuit breakers there would
  replace `rentsync-deploy`.
