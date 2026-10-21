data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  ssm_arn_prefix = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter"

  # GetParametersByPath is authorized against the path itself, so grant both the path and
  # everything under it.
  ssm_read_arns  = flatten([for p in var.ssm_read_paths : ["${local.ssm_arn_prefix}${p}", "${local.ssm_arn_prefix}${p}/*"]])
  ssm_write_arns = [for p in var.ssm_write_params : "${local.ssm_arn_prefix}${p}"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.name}-host"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name}-host"
  role = aws_iam_role.this.name
}

# Session Manager shell access with no inbound port (FR-010).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "host" {
  dynamic "statement" {
    for_each = var.ecr_repository_arn == null ? [] : [1]
    content {
      sid       = "EcrAuth"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.ecr_repository_arn == null ? [] : [1]
    content {
      sid       = "EcrPull"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = [var.ecr_repository_arn]
    }
  }

  # FR-023: each host reads only its own deployment's parameters (plus shared ingest creds).
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = local.ssm_read_arns
  }

  dynamic "statement" {
    for_each = length(local.ssm_write_arns) > 0 ? [1] : []
    content {
      sid       = "RecordDeployedTag"
      actions   = ["ssm:PutParameter"]
      resources = local.ssm_write_arns
    }
  }

  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "host" {
  name   = "${local.name}-host"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.host.json
}
