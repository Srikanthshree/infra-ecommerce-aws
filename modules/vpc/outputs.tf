output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the three public subnets (ALB)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the three private subnets (EKS nodes + RDS)"
  value       = aws_subnet.private[*].id
}

output "vpc_endpoints_sg_id" {
  description = "Security group ID for VPC interface endpoints — allow HTTPS from VPC CIDR"
  value       = aws_security_group.vpc_endpoints.id
}
