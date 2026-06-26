variable "project_name" {
  description = "Project name prefix for all resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. prod, staging)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Three availability zones for multi-AZ resilience."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly three availability zones must be provided."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the three public subnets (ALB only)."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "Exactly three public subnet CIDRs must be provided."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the three private subnets (EKS nodes + RDS)."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "Exactly three private subnet CIDRs must be provided."
  }
}

variable "eks_cluster_name" {
  description = "EKS cluster name — used for Kubernetes subnet tagging."
  type        = string
}

variable "aws_region" {
  description = "AWS region — used for VPC endpoint service names."
  type        = string
  default     = "us-east-1"
}
