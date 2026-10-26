# The shared deployment (shared-us): VPC, ECR, telemetry host, backups and budget
# (feature 002 research R1). Names derive from var.deployment_id (constitution VI, R17).

locals {
  name       = "rentsync-${var.deployment_id}"
  ssm_prefix = "/rentsync/${var.deployment_id}"

  default_tags = {
    DeploymentId = var.deployment_id
    Project      = "rentsync"
    ManagedBy    = "terraform"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}
