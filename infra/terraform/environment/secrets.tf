# This deployment's secrets and release state in SSM (research R9, R11). Secret values are
# written through write-only arguments, so they never reach state or plan output (FR-024).

resource "aws_ssm_parameter" "admin_token" {
  name             = "${local.ssm_prefix}/admin_token"
  type             = "SecureString"
  value_wo         = var.admin_token
  value_wo_version = var.admin_token_version
}

# A fresh value every run, but written only when the version changes, so the stored password
# is stable. Rotating it also needs ALTER USER on the host (runbook §Secret rotation).
ephemeral "random_password" "postgres" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "postgres_password" {
  name             = "${local.ssm_prefix}/postgres_password"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.postgres.result
  value_wo_version = var.postgres_password_version
}

# Runtime state owned by rentsync-deploy, not Terraform: created once, then only the host
# writes them (research R9).
resource "aws_ssm_parameter" "image_tag" {
  name  = "${local.ssm_prefix}/image_tag"
  type  = "String"
  value = "none"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "previous_image_tag" {
  name  = "${local.ssm_prefix}/previous_image_tag"
  type  = "String"
  value = "none"

  lifecycle {
    ignore_changes = [value]
  }
}

# RentSync's secrets (feature 003, contracts/host-changes.md), in a rentsync/ sub-path that
# rentsync-render-env reads with the rest of the deployment's path.
resource "aws_ssm_parameter" "rentsync_encryption_keys" {
  name             = "${local.ssm_prefix}/rentsync/encryption_keys"
  type             = "SecureString"
  value_wo         = var.rentsync_encryption_keys
  value_wo_version = var.rentsync_encryption_keys_version
}

resource "aws_ssm_parameter" "rentsync_operator_seed_password" {
  name             = "${local.ssm_prefix}/rentsync/operator_seed_password"
  type             = "SecureString"
  value_wo         = var.rentsync_operator_seed_password
  value_wo_version = var.rentsync_operator_seed_password_version
}

resource "aws_ssm_parameter" "rentsync_session_secret" {
  name             = "${local.ssm_prefix}/rentsync/session_secret"
  type             = "SecureString"
  value_wo         = var.rentsync_session_secret
  value_wo_version = var.rentsync_session_secret_version
}
