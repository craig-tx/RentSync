# Network surface and secret handling for an environment deployment (FR-009, FR-025, R11).

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
  deployment_id    = "dev-staging"
  environment      = "staging"
  hostname         = "pms-staging.example.com"
  vpc_cidr         = "10.41.0.0/16"
  subnet_cidr      = "10.41.1.0/24"
  private_ip       = "10.41.1.20"
  acme_email       = "ops@example.test"
  admin_token      = "0123456789abcdef0123456789abcdef"
}

run "only_http_and_https_from_the_internet" {
  command = plan

  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.public : r.from_port]) == toset([80, 443])
    error_message = "The deployment security group must admit exactly TCP 80 and 443 (FR-009)."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.public :
    r.ip_protocol == "tcp" && r.cidr_ipv4 == "0.0.0.0/0" && r.from_port == r.to_port])
    error_message = "Public rules must be single TCP ports from 0.0.0.0/0."
  }
}

run "secrets_are_write_only" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.admin_token.type == "SecureString" && aws_ssm_parameter.admin_token.value_wo_version == var.admin_token_version
    error_message = "admin_token must be a SecureString written through value_wo (R11)."
  }

  assert {
    condition     = aws_ssm_parameter.postgres_password.type == "SecureString" && aws_ssm_parameter.postgres_password.value_wo_version == var.postgres_password_version
    error_message = "postgres_password must be a SecureString written through value_wo (R11)."
  }
}

run "example_admin_token_rejected" {
  command = plan

  variables {
    admin_token = "change-me-admin-token"
  }

  expect_failures = [var.admin_token]
}

run "short_admin_token_rejected" {
  command = plan

  variables {
    admin_token = "0123456789abcdef0123456789abcde" # 31 characters
  }

  expect_failures = [var.admin_token]
}

run "user_data_fits_ec2_limit" {
  command = apply # mocked provider: nothing real is created

  # The volume ID is part of the user data, so it must be known: apply against the mocks.
  override_resource {
    target = module.host.aws_ebs_volume.data
    values = { id = "vol-0123456789abcdef0" }
  }

  # EC2 rejects user data over 16 KB (gzipped bytes). Host files are base64-encoded inside
  # cloud-init, so growing them eats this budget (research R6).
  assert {
    condition     = output.user_data_gzip_bytes < 16384
    error_message = "Gzipped user data is ${output.user_data_gzip_bytes} bytes; EC2's limit is 16384."
  }
}

run "non_production_hosts_are_deployable_by_the_shared_role" {
  command = plan

  assert {
    condition     = local.deployable_tag == "true"
    error_message = "Non-production hosts must be tagged rentsync:deployable=true."
  }
}

run "production_hosts_are_protected" {
  command = plan

  variables {
    deployment_id = "prod-us"
    environment   = "production"
    hostname      = "pms.example.com"
    vpc_cidr      = "10.42.0.0/16"
    subnet_cidr   = "10.42.1.0/24"
    private_ip    = "10.42.1.30"
    protected     = true
  }

  assert {
    condition     = local.deployable_tag == "protected"
    error_message = "Production hosts must be tagged rentsync:deployable=protected, reachable only by the prod-us release role."
  }
}
