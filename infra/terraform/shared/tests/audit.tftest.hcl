# Audit logging: one CloudTrail trail and the private, encrypted bucket that holds it and every
# VPC's Flow Logs. Mocked AWS; the account ID is fixed so names can be asserted.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

variables {
  region                    = "us-east-1"
  availability_zone         = "us-east-1a"
  telemetry_hostname        = "telemetry.example.com"
  deployment_id             = "shared-us"
  ami_id                    = "ami-0123456789abcdef0"
  telemetry_private_ip      = "10.40.1.10"
  acme_email                = "ops@example.test"
  openobserve_root_email    = "ops@example.test"
  openobserve_root_password = "Example-0nly-Passw0rd!"
  budget_email              = "ops@example.test"
}

run "trail" {
  command = plan

  assert {
    condition     = aws_cloudtrail.this.name == "rentsync-shared-us-trail"
    error_message = "The trail must be named from the DeploymentId."
  }

  assert {
    condition = (aws_cloudtrail.this.is_multi_region_trail &&
      aws_cloudtrail.this.include_global_service_events &&
    aws_cloudtrail.this.enable_log_file_validation)
    error_message = "The trail must cover every region and global services, with log file validation."
  }
}

run "log_bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket.logs.bucket == "rentsync-shared-us-logs-123456789012"
    error_message = "The log bucket must be named from the DeploymentId and the AWS account ID."
  }

  assert {
    condition = (aws_s3_bucket_public_access_block.logs.block_public_acls &&
      aws_s3_bucket_public_access_block.logs.block_public_policy &&
      aws_s3_bucket_public_access_block.logs.ignore_public_acls &&
    aws_s3_bucket_public_access_block.logs.restrict_public_buckets)
    error_message = "The log bucket must block all public access."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.logs.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The log bucket must be encrypted."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.logs.rule).expiration).days == 90
    error_message = "Logs must expire after 90 days, which caps the storage cost."
  }
}
