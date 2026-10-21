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

## Role `rentsync-github-actions` (releases)

**Trust**: the GitHub OIDC provider, with:

- `token.actions.githubusercontent.com:aud = sts.amazonaws.com`;
- `sub` like `repo:craig-tx/RentSync:environment:*` or
  `repo:craig-tx/RentSync:ref:refs/heads/main`. GitHub Environments are named by DeploymentId
  (`dev-staging`, `prod-us`), and the wildcard means a new deployment needs no trust change. The
  `ref` form is for the build job.

**Permissions**:

| Actions | Resources |
|---|---|
| `ecr:GetAuthorizationToken` | `*` |
| `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`, `ecr:BatchGetImage`, `ecr:DescribeImages` | `arn:aws:ecr:us-east-1:<account>:repository/shared-us/mock_pms` |
| `ssm:SendCommand` | `arn:aws:ssm:us-east-1::document/AWS-RunShellScript`, and `arn:aws:ec2:us-east-1:<account>:instance/*` with condition `ssm:resourceTag/rentsync:deployable = true` |
| `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations` | `*` |

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
