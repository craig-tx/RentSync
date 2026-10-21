# Telemetry network surface, budget and registry settings (FR-011, FR-035, R16).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  deployment_id             = "shared-us"
  ami_id                    = "ami-0123456789abcdef0"
  telemetry_private_ip      = "10.40.1.10"
  acme_email                = "ops@example.test"
  openobserve_root_email    = "ops@example.test"
  openobserve_root_password = "Example-0nly-Passw0rd!"
  budget_email              = "ops@example.test"
}

run "telemetry_surface" {
  command = plan

  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.telemetry_public : r.from_port]) == toset([80, 443])
    error_message = "The telemetry host must admit only TCP 80 and 443 from the internet (FR-009)."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.telemetry_public :
    r.ip_protocol == "tcp" && r.cidr_ipv4 == "0.0.0.0/0" && r.from_port == r.to_port])
    error_message = "Public telemetry rules must be single TCP ports from 0.0.0.0/0."
  }

  assert {
    condition = (aws_vpc_security_group_ingress_rule.otlp.from_port == 5080 &&
      aws_vpc_security_group_ingress_rule.otlp.to_port == 5080 &&
      aws_vpc_security_group_ingress_rule.otlp.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.otlp.cidr_ipv6 == null &&
    aws_vpc_security_group_ingress_rule.otlp.prefix_list_id == null)
    error_message = "OTLP 5080 must be admitted only from the otlp-client security group, never a CIDR (FR-011)."
  }
}

run "budget_alerts" {
  command = plan

  assert {
    condition     = aws_budgets_budget.monthly.name == "rentsync-shared-us-monthly" && tonumber(aws_budgets_budget.monthly.limit_amount) == var.budget_limit_usd
    error_message = "The monthly budget must be named from the DeploymentId and capped at budget_limit_usd (SC-009)."
  }

  assert {
    condition = toset([for n in aws_budgets_budget.monthly.notification : "${n.notification_type}:${n.threshold}"]) == toset([
      "ACTUAL:80", "ACTUAL:100", "FORECASTED:100"
    ])
    error_message = "The budget must alert at 80% and 100% actual and 100% forecast (FR-035)."
  }
}

run "registry" {
  command = plan

  assert {
    condition     = aws_ecr_repository.mock_pms.image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.mock_pms.image_scanning_configuration[0].scan_on_push
    error_message = "ECR tags must be immutable and scanned on push (R16)."
  }
}

run "weak_openobserve_password_rejected" {
  command = plan

  variables {
    openobserve_root_password = "alllowercase1" # no upper case, no special character
  }

  expect_failures = [var.openobserve_root_password]
}
