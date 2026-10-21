# Inputs for the shared deployment (contracts/workspace-variables.md §rentsync-shared-us).

variable "deployment_id" {
  type        = string
  description = "DeploymentId of the shared deployment, e.g. shared-us (constitution VI)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.deployment_id))
    error_message = "deployment_id must match ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ (constitution VI)."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  type        = string
  default     = "us-east-1a"
  description = "All hosts and data volumes live in this zone (research R3)."
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.40.1.0/24"
}

variable "ami_id" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI for every host (research R4)."
}

variable "telemetry_instance_type" {
  type    = string
  default = "t4g.small"
}

variable "telemetry_private_ip" {
  type        = string
  description = "Fixed private IP of the telemetry host; the OTLP endpoint (research R3, R8)."
}

variable "telemetry_hostname" {
  type    = string
  default = "telemetry.rentsync.org"
}

variable "acme_email" {
  type        = string
  description = "Let's Encrypt contact address."
}

variable "acme_ca" {
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
  description = "ACME directory. Use the Let's Encrypt staging URL for first bring-up (research R13)."
}

variable "openobserve_root_email" {
  type        = string
  description = "OpenObserve UI sign-in user."
}

variable "openobserve_root_password" {
  type        = string
  sensitive   = true
  ephemeral   = true
  description = "OpenObserve root password: 8-128 characters with upper, lower, digit and special."

  validation {
    condition     = length(var.openobserve_root_password) >= 8 && length(var.openobserve_root_password) <= 128
    error_message = "openobserve_root_password must be 8-128 characters."
  }
}

variable "openobserve_root_password_version" {
  type        = number
  default     = 1
  description = "Bump to write a changed openobserve_root_password to SSM."
}

variable "openobserve_db_password_version" {
  type        = number
  default     = 1
  description = "Bump to generate and write a new OpenObserve metadata database password."
}

variable "budget_limit_usd" {
  type        = number
  default     = 60
  description = "Monthly cost ceiling (SC-009)."
}

variable "budget_email" {
  type        = string
  description = "Budget alert recipient (FR-035). Set in the workspace, never committed."
}
