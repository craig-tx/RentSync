# This environment's own VPC, peered only with the shared deployment's VPC (ADR 0008).
# Staging and production each have one, so they share no network and have no route to each
# other; both reach the telemetry host over their peering connection, never the internet
# (FR-007, FR-011). Production would go further, with a separate AWS account per environment
# (Multi-Account Strategy via AWS Organizations; docs/deploy/production-differences.md).

module "network" {
  source = "../modules/network"

  name        = local.name
  vpc_cidr    = var.vpc_cidr
  subnet_cidr = var.subnet_cidr
  # The shared zone: the host and its data volume are zonal, and peering within a zone is free.
  availability_zone = local.shared.availability_zone

  flow_log_bucket_arn = local.shared.log_bucket_arn
}

# Same AWS account and region, so the connection accepts itself.
resource "aws_vpc_peering_connection" "shared" {
  vpc_id      = module.network.vpc_id
  peer_vpc_id = local.shared.vpc_id
  auto_accept = true

  tags = { Name = "${local.name}-to-shared" }
}

resource "aws_route" "to_shared" {
  route_table_id            = module.network.route_table_id
  destination_cidr_block    = local.shared.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared.id
}

# The return route lives in the shared route table but belongs to this deployment: it is
# created and destroyed with it. The shared route table has no inline routes, so a shared apply
# never removes it (infra/terraform/check_prevent_destroy.sh).
resource "aws_route" "from_shared" {
  route_table_id            = local.shared.route_table_id
  destination_cidr_block    = module.network.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared.id
}

# OTLP to the telemetry host, from this environment's subnet only. The subnet holds just this
# deployment's host (research R8).
resource "aws_vpc_security_group_ingress_rule" "otlp_from_here" {
  security_group_id = local.shared.telemetry_security_group_id
  description       = "OTLP from ${var.deployment_id}"
  ip_protocol       = "tcp"
  from_port         = 5080
  to_port           = 5080
  cidr_ipv4         = module.network.subnet_cidr

  tags = { Name = "${local.name}-otlp-to-telemetry" }
}
