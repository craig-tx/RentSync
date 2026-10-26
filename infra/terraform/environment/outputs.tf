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
  ]
}

output "user_data_gzip_bytes" {
  value = module.host.user_data_gzip_bytes
}
