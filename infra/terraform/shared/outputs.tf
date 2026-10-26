# Read by the environment root through terraform_remote_state, and by the runbook
# (contracts/workspace-variables.md).

# An environment peers its own VPC with this one, adds its return route to this route table,
# and admits its subnet to the telemetry security group (ADR 0008).
output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "route_table_id" {
  value = module.network.route_table_id
}

output "telemetry_security_group_id" {
  value = aws_security_group.telemetry.id
}

output "availability_zone" {
  value = var.availability_zone
}

output "ami_id" {
  value = var.ami_id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.mock_pms.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.mock_pms.arn
}

output "otlp_endpoint" {
  value = "http://${var.telemetry_private_ip}:5080/api/default"
}

output "ingest_ssm_path" {
  value = "${local.ssm_prefix}/openobserve/ingest"
}

output "telemetry_public_ip" {
  description = "DNS A record for the telemetry hostname (runbook §DNS)."
  value       = module.telemetry_host.public_ip
}

output "telemetry_instance_id" {
  value = module.telemetry_host.instance_id
}

output "ssm_parameter_names" {
  description = "Every SSM parameter this deployment owns (constitution VI tests)."
  value = [
    aws_ssm_parameter.openobserve_root_email.name,
    aws_ssm_parameter.ingest_user.name,
    aws_ssm_parameter.openobserve_root_password.name,
    aws_ssm_parameter.ingest_password.name,
    aws_ssm_parameter.openobserve_db_password.name,
  ]
}
