# Inputs for one deployment's network (ADR 0008).

variable "name" {
  type        = string
  description = "Name prefix, rentsync-<deployment_id> (constitution VI)."
}

variable "vpc_cidr" {
  type        = string
  description = "The deployment's own range. It must not overlap any VPC it peers with."

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be an IPv4 CIDR block, e.g. 10.41.0.0/16."
  }
}

variable "subnet_cidr" {
  type        = string
  description = "The public subnet, inside vpc_cidr."

  validation {
    condition     = can(cidrnetmask(var.subnet_cidr))
    error_message = "subnet_cidr must be an IPv4 CIDR block, e.g. 10.41.1.0/24."
  }
}

variable "availability_zone" {
  type        = string
  description = "Every deployment uses the same zone: hosts and volumes are zonal, and peering traffic within one zone is free."
}

variable "flow_log_bucket_arn" {
  type        = string
  description = "ARN of the shared deployment's log bucket, which receives this VPC's Flow Logs."

  validation {
    condition     = startswith(var.flow_log_bucket_arn, "arn:aws:s3:::")
    error_message = "flow_log_bucket_arn must be an S3 bucket ARN."
  }
}
