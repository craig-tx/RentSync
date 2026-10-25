# Contract: bootstrap IAM (created by hand, once)

The operator creates these in the AWS console during bootstrap (FR-006). The runbook has the
click path. No access keys are created. `<account>` is the AWS account ID.

## OIDC identity providers

| Provider URL | Audience |
|---|---|
| `https://app.terraform.io` | `aws.workload.identity` |
| `https://token.actions.githubusercontent.com` | `sts.amazonaws.com` |

## Role `rentsync-hcp-terraform` (used by all three workspaces)

**Trust**:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/app.terraform.io" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "app.terraform.io:aud": "aws.workload.identity" },
    "StringLike":   { "app.terraform.io:sub": "organization:craig-personal:project:RentSync:workspace:rentsync-*:run_phase:*" }
  }
}
```

**Permissions** (one customer-managed policy, `rentsync-hcp-terraform`). These are coarse on
purpose for a demo, and are listed in the production-differences document:

| Service | Actions | Resources |
|---|---|---|
| EC2 | `ec2:*` | `*`, with condition `aws:RequestedRegion = us-east-1` |
| IAM | `iam:*Role*`, `iam:*InstanceProfile*`, `iam:*RolePolicy*`, `iam:PassRole`, `iam:GetPolicy*`, `iam:List*` | `arn:aws:iam::<account>:role/rentsync-*`, `arn:aws:iam::<account>:instance-profile/rentsync-*`, plus the AWS-managed policies it attaches |
| SSM | `ssm:*Parameter*`, `ssm:AddTagsToResource`, `ssm:ListTagsForResource`, `ssm:DescribeParameters` | `arn:aws:ssm:us-east-1:<account>:parameter/rentsync/*` |
| ECR | `ecr:*` | `arn:aws:ecr:us-east-1:<account>:repository/*` (repositories are named `<deployment_id>/...`, so no fixed prefix exists), plus `ecr:GetAuthorizationToken` on `*` |
| DLM | `dlm:*` | `*` |
| Budgets | `budgets:*` | `arn:aws:budgets::<account>:budget/rentsync-*` |
| KMS | `kms:DescribeKey`, `kms:ListAliases` | `*` (AWS-managed keys only; no key is created) |

## GitHub release roles: one job, one role, exact trust

The security review on 2026-10-21 found that a wildcard trust (`environment:*`) let any branch
job that names a new GitHub Environment assume the release role. Such a job could push an image
under an upcoming commit's tag and get it to production past the reviewer. Each role below
therefore trusts **exact** subjects with `StringEquals`, and only one role can push images.
Every trust uses `token.actions.githubusercontent.com:aud = sts.amazonaws.com`.

Subjects use GitHub's **immutable** format, `repo:<owner>@<owner-id>/<repo>@<repo-id>:…`. The
repository was created after 2026-07-15, so its tokens never carry the older
`repo:craig-tx/RentSync:…` form, and a trust written that way would never match. Check the
prefix with `gh api repos/craig-tx/RentSync/actions/oidc/customization/sub`
(`sub_claim_prefix`).

### Role `rentsync-github-build` (image builds)

**Trust**: `sub` **exactly** `repo:craig-tx@16706018/RentSync@1427164274:ref:refs/heads/main`. Only jobs running on
`main` can build: `release.yml` and `deploy.yml` dispatched from `main`. See
`docs/deploy/iam/github-build-trust.json`.

**Permissions** (`docs/deploy/iam/github-build-policy.json`):

| Actions | Resources |
|---|---|
| `ecr:GetAuthorizationToken` | `*` |
| `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`, `ecr:BatchGetImage`, `ecr:DescribeImages` | `arn:aws:ecr:us-east-1:<account>:repository/*/mock_pms` |

It is the **only** principal that can push images. Builds output the image digest, and every
deploy pins `<sha>@sha256:<digest>` (research R9).

### Role `rentsync-github-actions` (non-production deploys)

**Trust**: `sub` **exactly** `repo:craig-tx@16706018/RentSync@1427164274:environment:dev-staging`. The `dev-staging`
Environment is limited to `main` (runbook ?Bootstrap step 7). Adding a side-by-side deployment
adds its Environment's exact subject to this list. That is a one-line change and the only IAM
edit a new deployment needs. See `docs/deploy/iam/github-actions-trust.json`.

**Permissions** (`docs/deploy/iam/github-actions-policy.json`):

| Actions | Resources |
|---|---|
| `ssm:SendCommand` | `arn:aws:ssm:us-east-1::document/AWS-RunShellScript`, and `arn:aws:ec2:us-east-1:<account>:instance/*` with condition `ssm:resourceTag/rentsync:deployable = true` |
| `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations` | `*` |

It cannot push images, and it cannot touch production: production hosts are tagged
`protected` (Terraform variable `protected = true` in `rentsync-prod-us`).

### Role `rentsync-github-actions-prod` (production releases)

Added after the 2026-10-21 code review. Without it, any job that could assume the release role
could run commands on production, and the `prod-us` approval would be enforced only by the
workflow, not by IAM.

**Trust**: the GitHub OIDC provider, with `aud = sts.amazonaws.com` and `sub` **exactly**
`repo:craig-tx@16706018/RentSync@1427164274:environment:prod-us` (StringEquals). GitHub issues that token only to
a job in the `prod-us` Environment, which is limited to `main` and gated by the required
reviewer. See `docs/deploy/iam/github-actions-prod-trust.json`.

**Permissions** (`docs/deploy/iam/github-actions-prod-policy.json`):

| Actions | Resources |
|---|---|
| `ssm:SendCommand` | `arn:aws:ssm:us-east-1::document/AWS-RunShellScript`, and `arn:aws:ec2:us-east-1:<account>:instance/*` with condition `ssm:resourceTag/rentsync:deployable = protected` |
| `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations` | `*` |

It has no ECR access: production only runs images the release role already built.

**How a job picks its role**:
- **Build jobs** use the repository variable `AWS_BUILD_ROLE_ARN` (`rentsync-github-build`).
- **Deploy jobs** use `vars.AWS_ROLE_ARN`. The repository-level value is
  `rentsync-github-actions`. The `prod-us` Environment defines its own `AWS_ROLE_ARN` =
  `rentsync-github-actions-prod`, which overrides the repository value for jobs in that
  Environment.

## Roles created by Terraform (not bootstrap)

These are listed so the bootstrap policy above covers them:

- `rentsync-dev-staging-host`;
- `rentsync-prod-us-host`;
- `rentsync-shared-us-host`;
- `rentsync-shared-us-dlm`, the DLM service role.

Every role follows the pattern `rentsync-<deployment_id>-*`, so the `rentsync-*` scope above
also covers any future side-by-side deployment.

## Cost allocation tag (Billing console, once)

Activate `DeploymentId` as a user-defined cost allocation tag. Cost Explorer then shows spend
per deployment (constitution VI). Tags appear for activation about 24 hours after the first
tagged resource exists.
