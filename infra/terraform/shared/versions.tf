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

  cloud {
    organization = "craig-personal"

    workspaces {
      project = "RentSync"
      tags    = ["rentsync-shared"]
    }
  }
}
