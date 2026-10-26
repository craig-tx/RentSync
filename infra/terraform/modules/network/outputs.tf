output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "subnet_id" {
  value = aws_subnet.public.id
}

output "subnet_cidr" {
  value = aws_subnet.public.cidr_block
}

output "route_table_id" {
  value = aws_route_table.public.id
}

output "availability_zone" {
  value = aws_subnet.public.availability_zone
}
