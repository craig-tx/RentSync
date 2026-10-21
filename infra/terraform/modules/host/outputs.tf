output "instance_id" {
  value = aws_instance.this.id
}

output "public_ip" {
  description = "The Elastic IP; the DNS A record points here (FR-021)."
  value       = aws_eip.this.public_ip
}

output "private_ip" {
  value = var.private_ip
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "role_name" {
  value = aws_iam_role.this.name
}

output "names" {
  description = "Every name this host owns, for the DeploymentId tests (constitution VI)."
  value = {
    instance         = aws_instance.this.tags["Name"]
    role             = aws_iam_role.this.name
    instance_profile = aws_iam_instance_profile.this.name
    eni              = aws_network_interface.this.tags["Name"]
    eip              = aws_eip.this.tags["Name"]
    data_volume      = aws_ebs_volume.data.tags["Name"]
  }
}

output "user_data_gzip_bytes" {
  description = "Size of the gzipped user data. EC2 rejects more than 16384 bytes (research R6)."
  value       = floor(length(base64gzip(local.user_data)) * 3 / 4)
}
