# One environment deployment: a host running the mock PMS stack (feature 002 research R1, R7).
# Everything it owns is named from var.deployment_id (constitution VI, research R17).

locals {
  name       = "rentsync-${var.deployment_id}"
  ssm_prefix = "/rentsync/${var.deployment_id}"
  db_name    = "mock_pms_${replace(var.deployment_id, "-", "_")}"

  deployable_tag = var.protected ? "protected" : "true"

  default_tags = {
    DeploymentId = var.deployment_id
    Project      = "rentsync"
    ManagedBy    = "terraform"
  }

  shared = data.terraform_remote_state.shared.outputs
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}

# Shared network, registry and telemetry endpoint. HCP Terraform authorizes this read once
# rentsync-shared-us shares its state with this workspace (runbook §Bootstrap).
data "terraform_remote_state" "shared" {
  backend = "remote"

  config = {
    organization = "craig-personal"
    workspaces = {
      name = var.shared_workspace
    }
  }
}
