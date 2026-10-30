output "public_ip" {
  description = "DNS A record for this deployment's hostname (runbook §DNS)."
  value       = module.host.public_ip
}

output "instance_id" {
  value = module.host.instance_id
}

output "url" {
  value = "https://${var.hostname}"
}

output "app_url" {
  description = "RentSync's public URL; the GitHub Environment's APP_URL (bootstrap-github.sh)."
  value       = "https://${var.app_hostname}"
}

output "db_name" {
  value = local.db_name
}

output "resource_names" {
  description = "Every resource name this deployment owns (constitution VI tests)."
  value = merge(module.host.names, {
    security_group = aws_security_group.this.name
  })
}

output "ssm_parameter_names" {
  description = "Every SSM parameter this deployment owns (constitution VI tests)."
  value = [
    aws_ssm_parameter.admin_token.name,
    aws_ssm_parameter.postgres_password.name,
    aws_ssm_parameter.image_tag.name,
    aws_ssm_parameter.previous_image_tag.name,
    aws_ssm_parameter.rentsync_encryption_keys.name,
    aws_ssm_parameter.rentsync_operator_seed_password.name,
    aws_ssm_parameter.rentsync_session_secret.name,
  ]
}

output "user_data_gzip_bytes" {
  value = module.host.user_data_gzip_bytes
}

output "network" {
  description = "This deployment's own network and the only range it routes to privately (ADR 0008)."
  value = {
    vpc_cidr          = module.network.vpc_cidr
    subnet_cidr       = module.network.subnet_cidr
    availability_zone = module.network.availability_zone
    private_routes    = [aws_route.to_shared.destination_cidr_block]
  }
}
