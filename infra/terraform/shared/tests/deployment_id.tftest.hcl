# DeploymentId rules for the shared deployment (constitution VI, research R17).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  region                    = "us-east-1"
  availability_zone         = "us-east-1a"
  telemetry_hostname        = "telemetry.example.com"
  deployment_id             = "shared-us"
  ami_id                    = "ami-0123456789abcdef0"
  telemetry_private_ip      = "10.40.1.10"
  vpc_cidr                  = "10.40.0.0/16"
  subnet_cidr               = "10.40.1.0/24"
  acme_email                = "ops@example.test"
  openobserve_root_email    = "ops@example.test"
  openobserve_root_password = "Example-0nly-Passw0rd!"
  budget_email              = "ops@example.test"
}

run "invalid_id" {
  command = plan

  variables {
    deployment_id = "-shared"
  }

  expect_failures = [var.deployment_id]
}

run "names_derive" {
  command = plan

  # The VPC, subnet, gateway and route table are named from this prefix (modules/network tests).
  assert {
    condition     = module.network.vpc_cidr == "10.40.0.0/16" && module.network.subnet_cidr == "10.40.1.0/24"
    error_message = "The shared deployment must own its network, from vpc_cidr and subnet_cidr."
  }

  assert {
    condition     = aws_ecr_repository.mock_pms.name == "shared-us/mock_pms"
    error_message = "The ECR repository must be named <deployment_id>/mock_pms."
  }

  assert {
    condition     = alltrue([for n in output.ssm_parameter_names : startswith(n, "/rentsync/shared-us/")])
    error_message = "Every SSM parameter must live under /rentsync/<deployment_id>/."
  }

  assert {
    condition     = local.default_tags["DeploymentId"] == "shared-us"
    error_message = "Provider default_tags must carry DeploymentId."
  }
}
