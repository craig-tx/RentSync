# OpenObserve credentials in SSM (research R11). Secret values are written through
# write-only arguments, so they never reach state or plan output (FR-024).

resource "aws_ssm_parameter" "openobserve_root_email" {
  name  = "${local.ssm_prefix}/openobserve/root_email"
  type  = "String"
  value = var.openobserve_root_email
}

resource "aws_ssm_parameter" "ingest_user" {
  name  = "${local.ssm_prefix}/openobserve/ingest/user"
  type  = "String"
  value = var.openobserve_root_email
}

resource "aws_ssm_parameter" "openobserve_root_password" {
  name             = "${local.ssm_prefix}/openobserve/root_password"
  type             = "SecureString"
  value_wo         = var.openobserve_root_password
  value_wo_version = var.openobserve_root_password_version
}

# Collectors use the root credentials for ingest; production would use a per-environment
# ingest-only OpenObserve account (research R8, docs/deploy/production-differences.md).
resource "aws_ssm_parameter" "ingest_password" {
  name             = "${local.ssm_prefix}/openobserve/ingest/password"
  type             = "SecureString"
  value_wo         = var.openobserve_root_password
  value_wo_version = var.openobserve_root_password_version
}

# A fresh value every run, but written only when the version changes, so the stored password
# is stable.
ephemeral "random_password" "openobserve_db" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "openobserve_db_password" {
  name             = "${local.ssm_prefix}/openobserve/db_password"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.openobserve_db.result
  value_wo_version = var.openobserve_db_password_version
}
