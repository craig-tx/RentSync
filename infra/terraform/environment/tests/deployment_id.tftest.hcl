# DeploymentId rules (constitution VI; feature 002 FR-038 to FR-042, research R17).
# Mocked AWS (random is real: it runs locally and mocks cannot serve ephemeral resources).
# Plan-only, so every asserted value comes from config.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

override_data {
  target = data.terraform_remote_state.shared
  values = {
    outputs = {
      vpc_id                      = "vpc-0123456789abcdef0"
      vpc_cidr                    = "10.40.0.0/16"
      route_table_id              = "rtb-0123456789abcdef0"
      telemetry_security_group_id = "sg-0123456789abcdef0"
      availability_zone           = "us-east-1a"
      ami_id                      = "ami-0123456789abcdef0"
      ecr_repository_url          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms"
      ecr_repository_arn          = "arn:aws:ecr:us-east-1:123456789012:repository/shared-us/mock_pms"
      otlp_endpoint               = "http://10.40.1.10:5080/api/default"
      ingest_ssm_path             = "/rentsync/shared-us/openobserve/ingest"
    }
  }
}

variables {
  region           = "us-east-1"
  hcp_organization = "example-org"
  deployment_id    = "pr-42"
  environment      = "staging"
  hostname         = "pms-pr-42.example.com"
  vpc_cidr         = "10.43.0.0/16"
  subnet_cidr      = "10.43.1.0/24"
  private_ip       = "10.43.1.42"
  acme_email       = "ops@example.test"
  admin_token      = "0123456789abcdef0123456789abcdef"
}

run "invalid_id" {
  command = plan

  variables {
    deployment_id = "Prod_US"
  }

  expect_failures = [var.deployment_id]
}

run "names_derive" {
  command = plan

  assert {
    condition     = output.resource_names.instance == "rentsync-pr-42-host"
    error_message = "The instance Name must be rentsync-<deployment_id>-host."
  }

  assert {
    condition     = output.resource_names.role == "rentsync-pr-42-host"
    error_message = "The IAM role must be named rentsync-<deployment_id>-host."
  }

  assert {
    condition     = alltrue([for n in output.ssm_parameter_names : startswith(n, "/rentsync/pr-42/")])
    error_message = "Every SSM parameter must live under /rentsync/<deployment_id>/."
  }

  assert {
    condition     = output.db_name == "mock_pms_pr_42"
    error_message = "The database name must be mock_pms_<deployment_id with _>."
  }

  # Mocked providers don't compute tags_all; the real tags are proven live in T055.
  assert {
    condition     = local.default_tags["DeploymentId"] == "pr-42"
    error_message = "Provider default_tags must carry DeploymentId."
  }
}

run "prod" {
  command = plan

  variables {
    deployment_id = "prod-us"
    environment   = "production"
    hostname      = "pms.example.com"
    vpc_cidr      = "10.42.0.0/16"
    subnet_cidr   = "10.42.1.0/24"
    private_ip    = "10.42.1.30"
  }
}

run "staging" {
  command = plan

  variables {
    deployment_id = "dev-staging"
    hostname      = "pms-staging.example.com"
    vpc_cidr      = "10.41.0.0/16"
    subnet_cidr   = "10.41.1.0/24"
    private_ip    = "10.41.1.20"
  }
}

run "disjoint" {
  command = plan

  assert {
    condition = length(setintersection(
      toset(concat(values(run.prod.resource_names), run.prod.ssm_parameter_names)),
      toset(concat(values(run.staging.resource_names), run.staging.ssm_parameter_names))
    )) == 0
    error_message = "Two deployments must not share any owned name or parameter path."
  }
}
