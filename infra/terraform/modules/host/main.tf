locals {
  name = "rentsync-${var.deployment_id}"
  # Graviton families (t4g, m7g, ...) are arm64; everything else here is x86_64 (research R4).
  arch = can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*\\.", var.instance_type)) ? "aarch64" : "x86_64"

  # Files every host needs, from infra/host/ (one copy of each; research R6). Roots add the
  # role-specific stack (Compose file, Caddyfile, Collector config, deploy script).
  host_dir = "${path.module}/../../../host"
  base_files = {
    "/usr/local/bin/rentsync-boot"                       = { content = file("${local.host_dir}/bin/rentsync-boot"), permissions = "0755" }
    "/usr/local/bin/rentsync-render-env"                 = { content = file("${local.host_dir}/bin/rentsync-render-env"), permissions = "0755" }
    "/usr/local/bin/rentsync-start"                      = { content = file("${local.host_dir}/bin/rentsync-start"), permissions = "0755" }
    "/etc/systemd/system/rentsync-boot.service"          = { content = file("${local.host_dir}/systemd/rentsync-boot.service"), permissions = "0644" }
    "/etc/systemd/system/rentsync.service"               = { content = file("${local.host_dir}/systemd/rentsync.service"), permissions = "0644" }
    "/etc/systemd/system/rentsync-prune.service"         = { content = file("${local.host_dir}/systemd/rentsync-prune.service"), permissions = "0644" }
    "/etc/systemd/system/rentsync-prune.timer"           = { content = file("${local.host_dir}/systemd/rentsync-prune.timer"), permissions = "0644" }
    "/etc/systemd/system/docker.service.d/rentsync.conf" = { content = file("${local.host_dir}/systemd/docker-rentsync.conf"), permissions = "0644" }
    "/etc/docker/daemon.json"                            = { content = file("${local.host_dir}/daemon.json"), permissions = "0644" }
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    files           = merge(local.base_files, var.files)
    host_env        = merge(var.host_env, { VOLUME_ID = aws_ebs_volume.data.id })
    compose_version = var.compose_version
    compose_arch    = local.arch
    compose_sha256  = var.compose_sha256[local.arch]
  })
}

resource "aws_network_interface" "this" {
  subnet_id       = var.subnet_id
  private_ips     = [var.private_ip]
  security_groups = var.security_group_ids

  tags = { Name = "${local.name}-eni" }
}

resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  iam_instance_profile        = aws_iam_instance_profile.this.name
  user_data_base64            = base64gzip(local.user_data)
  user_data_replace_on_change = true

  primary_network_interface {
    network_interface_id = aws_network_interface.this.id
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  # Provider default_tags don't reach root volumes, so tag them here (constitution VI).
  # volume_tags is deliberately not used: it would fight the data volume's own tags.
  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    encrypted   = true
    tags = {
      Name         = "${local.name}-root"
      DeploymentId = var.deployment_id
      Project      = "rentsync"
      ManagedBy    = "terraform"
    }
  }

  tags = merge({ Name = "${local.name}-host" }, var.extra_tags)
}

# The address belongs to the network interface, so it survives instance replacement.
resource "aws_eip" "this" {
  domain = "vpc"
  tags   = { Name = "${local.name}-eip" }
}

resource "aws_eip_association" "this" {
  allocation_id        = aws_eip.this.id
  network_interface_id = aws_network_interface.this.id
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_gib
  type              = "gp3"
  encrypted         = true
  snapshot_id       = var.data_snapshot_id

  tags = {
    Name              = "${local.name}-data"
    "rentsync:backup" = "daily"
  }

  # FR-034: destroying or replacing the data volume needs a reviewed code change
  # (runbook §Backup restore, §Teardown).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true # lets Postgres stop cleanly before a detach
}
