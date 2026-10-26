# One deployment's network: a VPC with one public subnet, an internet gateway and a route table
# (feature 002 research R3; ADR 0008). Every deployment owns its own copy, so staging and
# production share no network; each environment reaches telemetry only through a peering
# connection to the shared deployment's VPC.
#
# Routes are standalone aws_route resources, never inline route blocks: an environment adds its
# return route to the shared route table from its own workspace, and an inline block would
# delete it on the next shared apply (infra/terraform/check_prevent_destroy.sh).

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.name}-subnet" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-rt" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
