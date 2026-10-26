# The shared telemetry host (OpenObserve) and the network rules for OTLP ingest
# (research R7, R8, R12). Security group rules are standalone resources.

resource "aws_security_group" "telemetry" {
  name        = "${local.name}-sg"
  description = "Telemetry host: HTTPS UI from the internet, OTLP from peered environment subnets"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "telemetry_public" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.telemetry.id
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

# FR-011: OTLP ingest (port 5080) is never open to the internet. Each environment adds its own
# standalone rule admitting its subnet over its peering connection (environment/network.tf), so
# adding a deployment never edits this file (research R17).

resource "aws_vpc_security_group_egress_rule" "telemetry_all" {
  security_group_id = aws_security_group.telemetry.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

module "telemetry_host" {
  source = "../modules/host"

  deployment_id      = var.deployment_id
  ami_id             = var.ami_id
  instance_type      = var.telemetry_instance_type
  availability_zone  = var.availability_zone
  subnet_id          = module.network.subnet_id
  private_ip         = var.telemetry_private_ip
  security_group_ids = [aws_security_group.telemetry.id]
  ssm_read_paths     = [local.ssm_prefix]

  # The OpenObserve stack (research R7). One copy of each file, read from infra/host/.
  files = {
    "/opt/rentsync/compose.yaml" = { content = file("${path.module}/../../host/compose.telemetry.yaml"), permissions = "0644" }
    "/opt/rentsync/Caddyfile"    = { content = file("${path.module}/../../host/Caddyfile.telemetry"), permissions = "0644" }
  }
  host_env = {
    HOST_ROLE      = "telemetry"
    DEPLOYMENT_ID  = var.deployment_id
    SITE_HOSTNAME  = var.telemetry_hostname
    PRIVATE_IP     = var.telemetry_private_ip
    DB_NAME        = "openobserve_${replace(var.deployment_id, "-", "_")}"
    ACME_EMAIL     = var.acme_email
    ACME_CA        = var.acme_ca
    AWS_REGION     = var.region
    SSM_READ_PATHS = local.ssm_prefix
  }

  depends_on = [module.network]
}
