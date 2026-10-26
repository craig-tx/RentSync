# The per-deployment network (ADR 0008). Mocked AWS; plan-only, so values come from config.

mock_provider "aws" {}

variables {
  name              = "rentsync-dev-staging"
  vpc_cidr          = "10.41.0.0/16"
  subnet_cidr       = "10.41.1.0/24"
  availability_zone = "us-east-1a"
}

run "names_derive" {
  command = plan

  assert {
    condition = (aws_vpc.this.tags["Name"] == "rentsync-dev-staging-vpc" &&
      aws_subnet.public.tags["Name"] == "rentsync-dev-staging-subnet" &&
      aws_internet_gateway.this.tags["Name"] == "rentsync-dev-staging-igw" &&
    aws_route_table.public.tags["Name"] == "rentsync-dev-staging-rt")
    error_message = "Network names must be <name>-vpc, -subnet, -igw and -rt (constitution VI)."
  }
}

run "ranges_and_zone" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.41.0.0/16" && aws_subnet.public.cidr_block == "10.41.1.0/24"
    error_message = "The VPC and subnet must use the given ranges."
  }

  assert {
    condition     = aws_subnet.public.availability_zone == "us-east-1a"
    error_message = "The subnet must be in the given zone."
  }
}

# The internet route is its own resource. Inline route blocks, which would be authoritative and
# delete routes that peered deployments add, are caught by infra/terraform/check_prevent_destroy.sh.
run "internet_route_is_standalone" {
  command = plan

  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "The default route must be a standalone aws_route."
  }
}

run "bad_range_rejected" {
  command = plan

  variables {
    vpc_cidr = "10.41.0.0"
  }

  expect_failures = [var.vpc_cidr]
}
