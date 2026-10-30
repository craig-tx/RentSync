# One EC2 host whose public IP, private IP and data volume survive the instance being
# replaced (feature 002 research R3, R6). Every name derives from deployment_id
# (constitution VI).

variable "deployment_id" {
  type        = string
  description = "DeploymentId of the deployment that owns this host, e.g. prod-us."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.deployment_id))
    error_message = "deployment_id must match ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ (constitution VI)."
  }
}

variable "ami_id" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI. Changing it replaces the host (research R4)."
}

variable "instance_type" {
  type = string
}

variable "availability_zone" {
  type        = string
  description = "Must match the subnet's zone; the data volume is zonal."
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type        = string
  description = "Fixed private IP on the standalone network interface (configuration, research R3)."
}

variable "security_group_ids" {
  type = list(string)
}

variable "files" {
  type = map(object({
    content     = string
    permissions = string
  }))
  description = "Files cloud-init writes, keyed by absolute path. No secrets (research R6)."
}

variable "host_env" {
  type        = map(string)
  description = "Non-secret settings written to /etc/rentsync/host.env. VOLUME_ID is added here."
}

variable "root_volume_gib" {
  type    = number
  default = 16
}

variable "data_volume_gib" {
  type    = number
  default = 10
}

variable "swap_mib" {
  type        = number
  default     = 1024
  description = "Swap file on the root disk, created at first boot by rentsync-swap; 0 for none (research R4)."

  validation {
    condition     = var.swap_mib >= 0 && floor(var.swap_mib) == var.swap_mib && var.swap_mib < var.root_volume_gib * 1024 / 4
    error_message = "swap_mib must be a whole number of MiB, under a quarter of the root disk."
  }
}

variable "data_snapshot_id" {
  type        = string
  default     = null
  description = "Snapshot to create the data volume from; used only by the restore procedure (research R14)."
}

variable "ssm_read_paths" {
  type        = list(string)
  description = "Bare SSM paths the host may read, such as /rentsync/prod-us (no trailing /*)."
}

variable "ssm_write_params" {
  type        = list(string)
  default     = []
  description = "Full SSM parameter names the host may overwrite (image_tag, previous_image_tag)."
}

variable "ecr_repository_arns" {
  type        = list(string)
  default     = []
  description = "Repositories the host may pull from; empty for hosts that pull no private image."
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

variable "compose_version" {
  type        = string
  default     = "v5.6.0"
  description = "Docker Compose plugin release installed by cloud-init (plan.md Dependencies)."
}

variable "compose_sha256" {
  type        = map(string)
  description = "sha256 of docker-compose-linux-<arch> for compose_version, from its checksums.txt."
  default = {
    aarch64 = "733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2"
    x86_64  = "40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a"
  }
}
