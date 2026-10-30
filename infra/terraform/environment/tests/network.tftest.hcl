# Network isolation (ADR 0008; FR-007, FR-011). Each environment owns its VPC, peers only with
# the shared VPC, routes privately only to it, and admits only its own subnet to telemetry.
# Mocked AWS; the apply runs create nothing real.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

override_data {
  target = data.terraform_remote_state.shared
  values = {
    outputs = {
      vpc_id                      = "vpc-0aaaaaaaaaaaaaaa0"
      vpc_cidr                    = "10.40.0.0/16"
      route_table_id              = "rtb-0aaaaaaaaaaaaaaa0"
      telemetry_security_group_id = "sg-0aaaaaaaaaaaaaaa0"
      availability_zone           = "us-east-1a"
      ami_id                      = "ami-0123456789abcdef0"
      ecr_repository_url          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms"
      ecr_repository_arn          = "arn:aws:ecr:us-east-1:123456789012:repository/shared-us/mock_pms"
      otlp_endpoint               = "http://10.40.1.10:5080/api/default"
      ingest_ssm_path             = "/rentsync/shared-us/openobserve/ingest"
      log_bucket_arn              = "arn:aws:s3:::rentsync-shared-us-logs-123456789012"
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
  app_hostname     = "app-staging.example.com"

  rentsync_encryption_keys        = "k1=VEVTVC1PTkxZLUtFWS1GT1ItVEVSUkFGT1JNLVRFU1Q="
  rentsync_operator_seed_password = "test-only-seed-password"
  rentsync_session_secret         = "test-only-session-secret-0123456789abcdef"
}

run "staging" {
  command = plan

  assert {
    condition     = aws_vpc_peering_connection.shared.peer_vpc_id == "vpc-0aaaaaaaaaaaaaaa0" && aws_vpc_peering_connection.shared.auto_accept
    error_message = "The environment must peer with the shared VPC, and only it."
  }

  assert {
    condition = (aws_route.to_shared.destination_cidr_block == "10.40.0.0/16" &&
      aws_route.from_shared.route_table_id == "rtb-0aaaaaaaaaaaaaaa0" &&
    aws_route.from_shared.destination_cidr_block == "10.41.0.0/16")
    error_message = "Routes must connect this VPC and the shared VPC in both directions, and nothing else."
  }

  assert {
    condition = (aws_vpc_security_group_ingress_rule.otlp_from_here.security_group_id == "sg-0aaaaaaaaaaaaaaa0" &&
      aws_vpc_security_group_ingress_rule.otlp_from_here.from_port == 5080 &&
      aws_vpc_security_group_ingress_rule.otlp_from_here.to_port == 5080 &&
    aws_vpc_security_group_ingress_rule.otlp_from_here.cidr_ipv4 == "10.41.1.0/24")
    error_message = "Telemetry must admit OTLP 5080 from this environment's subnet only (FR-011)."
  }

  assert {
    condition     = output.network.availability_zone == "us-east-1a"
    error_message = "The environment subnet must be in the shared zone (zonal volumes; free peering traffic)."
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
    protected     = true
  }
}

run "staging_and_production_are_isolated" {
  command = plan

  assert {
    condition     = run.staging.network.vpc_cidr != run.prod.network.vpc_cidr
    error_message = "Staging and production must have separate VPCs."
  }

  assert {
    condition = (run.staging.network.private_routes == ["10.40.0.0/16"] &&
    run.prod.network.private_routes == ["10.40.0.0/16"])
    error_message = "Each environment must route privately only to the shared VPC, never to the other environment."
  }
}
