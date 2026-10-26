# Inputs for one environment deployment (contracts/workspace-variables.md). Staging and
# production run this same code with different workspace variables (FR-002).

variable "deployment_id" {
  type        = string
  description = "DeploymentId, e.g. dev-staging or prod-us (constitution VI)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.deployment_id))
    error_message = "deployment_id must match ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ (constitution VI)."
  }
}

variable "environment" {
  type        = string
  description = "deployment.environment for telemetry."

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "shared_workspace" {
  type        = string
  default     = "rentsync-shared-us"
  description = "HCP workspace of the shared deployment this one uses."
}

variable "region" {
  type        = string
  description = "AWS region, from the deployment settings (bootstrap-hcp.rb)."
}

variable "hcp_organization" {
  type        = string
  description = "HCP Terraform organization holding the shared workspace, from the deployment settings."
}

variable "hostname" {
  type        = string
  description = "Public hostname, e.g. pms-staging.example.com (DNS set by hand, FR-021)."
}

variable "vpc_cidr" {
  type        = string
  description = "This deployment's own VPC range; must not overlap the shared VPC or another deployment's (ADR 0008)."
}

variable "subnet_cidr" {
  type        = string
  description = "This deployment's public subnet, inside vpc_cidr."
}

variable "private_ip" {
  type        = string
  description = "Fixed private IP of the host, inside subnet_cidr (configuration, research R3)."

  validation {
    condition     = can(cidrnetmask("${var.private_ip}/32"))
    error_message = "private_ip must be an IPv4 address, e.g. 10.41.1.20."
  }
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
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

variable "admin_token" {
  type        = string
  sensitive   = true
  ephemeral   = true
  description = "Bearer token for /admin/*. Generate with openssl rand -hex 32; never the example value."

  validation {
    condition     = length(var.admin_token) >= 32 && var.admin_token != "change-me-admin-token" && can(regex("^[A-Za-z0-9._~-]+$", var.admin_token))
    error_message = "admin_token must be at least 32 URL-safe characters (openssl rand -hex 32) and not the .env.example value (FR-025)."
  }
}

variable "admin_token_version" {
  type        = number
  default     = 1
  description = "Bump to write a changed admin_token to SSM (research R11)."
}

variable "postgres_password_version" {
  type        = number
  default     = 1
  description = "Bump to generate and write a new Postgres password (runbook §Secret rotation)."
}

variable "data_snapshot_id" {
  type        = string
  default     = null
  description = "Restore only (runbook §Backup restore, research R14)."
}

variable "protected" {
  type        = bool
  default     = false
  description = "true for production: the host is tagged rentsync:deployable=protected, which only the prod-us release role may run commands on (contracts/bootstrap-iam.md)."
}
