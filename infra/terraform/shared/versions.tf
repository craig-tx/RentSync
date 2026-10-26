# rentsync-shared-us: the shared deployment (VPC, ECR, telemetry host, backups, budget).
# Research R1, R17.
terraform {
  required_version = ">= 1.11" # write-only arguments and ephemeral resources (research R11)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # The organization comes from TF_CLOUD_ORGANIZATION: the rentsync-aws variable set provides it
  # to every run (bootstrap-hcp.rb), and you export it for local commands. A cloud block can't
  # read Terraform variables.
  cloud {
    workspaces {
      project = "RentSync"
      tags    = ["rentsync-shared"]
    }
  }
}
