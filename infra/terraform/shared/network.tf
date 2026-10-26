# The shared deployment's own VPC (ADR 0008). It holds only the telemetry host. Each
# environment has its own VPC and peers with this one, so environments never share a network or
# reach each other. Production would go further, with a separate AWS account per environment
# (Multi-Account Strategy via AWS Organizations; docs/deploy/production-differences.md).

module "network" {
  source = "../modules/network"

  name              = local.name
  vpc_cidr          = var.vpc_cidr
  subnet_cidr       = var.subnet_cidr
  availability_zone = var.availability_zone
}
