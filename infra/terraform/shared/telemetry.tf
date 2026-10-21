# The shared telemetry host (OpenObserve) and the network rules for OTLP ingest
# (research R7, R8, R12). Security group rules are standalone resources.

# Every environment host attaches this group; the telemetry host admits OTLP only from its
# members, so adding a deployment never edits a shared rule (research R17).
resource "aws_security_group" "otlp_client" {
  name        = "${local.name}-otlp-client"
  description = "Members may send OTLP to the telemetry host"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-otlp-client" }
}

resource "aws_vpc_security_group_egress_rule" "otlp_client_all" {
  security_group_id = aws_security_group.otlp_client.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "telemetry" {
  name        = "${local.name}-sg"
  description = "Telemetry host: HTTPS UI from the internet, OTLP from environment hosts"
  vpc_id      = aws_vpc.this.id

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

# FR-011: OTLP ingest stays inside the VPC.
resource "aws_vpc_security_group_ingress_rule" "otlp" {
  security_group_id            = aws_security_group.telemetry.id
  ip_protocol                  = "tcp"
  from_port                    = 5080
  to_port                      = 5080
  referenced_security_group_id = aws_security_group.otlp_client.id
}

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
  subnet_id          = aws_subnet.public.id
  private_ip         = var.telemetry_private_ip
  security_group_ids = [aws_security_group.telemetry.id]
  ssm_read_paths     = [local.ssm_prefix]

  # The OpenObserve stack is added in US3 (tasks T066-T069).
  files = {}
  host_env = {
    HOST_ROLE      = "telemetry"
    DEPLOYMENT_ID  = var.deployment_id
    AWS_REGION     = var.region
    SSM_READ_PATHS = local.ssm_prefix
  }

  depends_on = [aws_route_table_association.public]
}
