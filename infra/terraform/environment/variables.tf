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
  default = "t4g.micro"
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

# --- RentSync's API (feature 003, contracts/host-changes.md) -----------------------------------

variable "app_hostname" {
  type        = string
  description = "RentSync's public hostname, e.g. app-staging.example.com, on the same Elastic IP as hostname (DNS set by hand)."
}

variable "rentsync_encryption_keys" {
  type        = string
  sensitive   = true
  ephemeral   = true
  description = "key_id=base64(32 random bytes)[,...]; the first encrypts, every listed key decrypts. Generate: printf 'k1=%s' \"$(openssl rand -base64 32)\"."

  # Key IDs as Crypto::Box accepts them; each key exactly 32 bytes of base64.
  validation {
    condition = (can(regex("^[A-Za-z0-9_-]{1,32}=[A-Za-z0-9+/]{43}=(,[A-Za-z0-9_-]{1,32}=[A-Za-z0-9+/]{43}=)*$", var.rentsync_encryption_keys))
    && !strcontains(var.rentsync_encryption_keys, "REVWLU9OTFktS0VZLU5FVkVSLVVTRS1PTi1BLUhPU1Q="))
    error_message = "rentsync_encryption_keys must be key_id=<32 bytes of base64>[,...] (printf 'k1=%s' \"$(openssl rand -base64 32)\") and must not contain the .env.example key."
  }
}

variable "rentsync_encryption_keys_version" {
  type        = number
  default     = 1
  description = "Bump to write a changed rentsync_encryption_keys to SSM (ADR-0007)."
}

variable "rentsync_operator_seed_password" {
  type        = string
  sensitive   = true
  ephemeral   = true
  description = "Sign-in password given to the seeded operators when they are first created. Generate: openssl rand -base64 24."

  validation {
    condition     = length(var.rentsync_operator_seed_password) >= 16 && var.rentsync_operator_seed_password != "local-dev-operator-pass"
    error_message = "rentsync_operator_seed_password must be at least 16 characters and not the .env.example value."
  }
}

variable "rentsync_operator_seed_password_version" {
  type        = number
  default     = 1
  description = "Bump to write a changed rentsync_operator_seed_password to SSM. Existing operators keep their password."
}

variable "rentsync_session_secret" {
  type        = string
  sensitive   = true
  ephemeral   = true
  description = "Keys the CSRF HMAC. Generate: openssl rand -hex 32."

  validation {
    condition     = can(regex("^[A-Za-z0-9._~-]{32,}$", var.rentsync_session_secret)) && var.rentsync_session_secret != "local-dev-session-secret-change-me-0123456789"
    error_message = "rentsync_session_secret must be at least 32 URL-safe characters (openssl rand -hex 32) and not the .env.example value."
  }
}

variable "rentsync_session_secret_version" {
  type        = number
  default     = 1
  description = "Bump to write a changed rentsync_session_secret to SSM."
}
