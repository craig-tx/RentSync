# Daily snapshots of every data volume, 7 kept (FR-032, research R14).

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
  acme_email                = "ops@example.test"
  openobserve_root_email    = "ops@example.test"
  openobserve_root_password = "Example-0nly-Passw0rd!"
  budget_email              = "ops@example.test"
}

run "daily_snapshots_keep_seven" {
  command = plan

  assert {
    condition     = aws_dlm_lifecycle_policy.daily.tags["Name"] == "rentsync-shared-us-daily" && aws_dlm_lifecycle_policy.daily.state == "ENABLED"
    error_message = "The snapshot policy must be named from the DeploymentId and enabled."
  }

  assert {
    condition = (aws_dlm_lifecycle_policy.daily.policy_details[0].resource_types == tolist(["VOLUME"]) &&
    aws_dlm_lifecycle_policy.daily.policy_details[0].target_tags == tomap({ "rentsync:backup" = "daily" }))
    error_message = "The policy must target volumes tagged rentsync:backup=daily (every host's data volume)."
  }

  assert {
    condition = (aws_dlm_lifecycle_policy.daily.policy_details[0].schedule[0].create_rule[0].interval == 24 &&
      aws_dlm_lifecycle_policy.daily.policy_details[0].schedule[0].create_rule[0].interval_unit == "HOURS" &&
    aws_dlm_lifecycle_policy.daily.policy_details[0].schedule[0].create_rule[0].times == tolist(["05:00"]))
    error_message = "Snapshots must run every 24 hours at 05:00 UTC (FR-032)."
  }

  assert {
    condition     = aws_dlm_lifecycle_policy.daily.policy_details[0].schedule[0].retain_rule[0].count == 7
    error_message = "Seven daily snapshots must be kept (FR-032)."
  }

  assert {
    condition     = aws_dlm_lifecycle_policy.daily.policy_details[0].schedule[0].copy_tags
    error_message = "Snapshots must copy the volume's tags, so each shows its DeploymentId."
  }
}
