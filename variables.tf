# ============================================================
# Core Configuration
# ============================================================

variable "aws_region" {
  description = "AWS region where all resources will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name; used as a prefix for all resource names."
  type        = string
  default     = "ecommerce"
}

variable "environment" {
  description = "Deployment environment identifier (e.g. prod, staging)."
  type        = string
  default     = "prod"
}

# ============================================================
# Networking
# ============================================================

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Three availability zones for multi-AZ resilience."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly three availability zones must be specified."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the 3 public subnets (ALB only)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "Exactly three public subnet CIDRs must be specified."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the 3 private subnets (EKS nodes and RDS)."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "Exactly three private subnet CIDRs must be specified."
  }
}

# ============================================================
# EKS
# ============================================================

variable "eks_cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "ecommerce-eks"
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.30"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the EKS managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "Maximum number of EKS worker nodes (for cluster autoscaler)."
  type        = number
  default     = 6
}

variable "eks_node_disk_size_gb" {
  description = "Root EBS volume size (GB) for each EKS worker node."
  type        = number
  default     = 50
}

# ============================================================
# RDS PostgreSQL
# ============================================================

variable "db_name" {
  description = "Initial database name created inside the PostgreSQL instance."
  type        = string
  default     = "ecommerce_db"
}

variable "db_username" {
  description = "Master username for the PostgreSQL instance. The password is auto-generated and stored in AWS Secrets Manager — it is NEVER stored in Terraform state or code."
  type        = string
  default     = "ecommerce_admin"
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.medium"
}

variable "db_allocated_storage_gb" {
  description = "Initial allocated storage for RDS (GB). Auto-scaling up to 500 GB is enabled."
  type        = number
  default     = 20
}

# ============================================================
# GitHub OIDC
# ============================================================

variable "github_org" {
  description = "GitHub organisation name or personal account username. Used to scope the OIDC trust policy."
  type        = string
  default     = "Srikanthshree"
}

variable "eks_admin_iam_arns" {
  description = "IAM principal ARNs granted cluster-admin access for local kubectl (e.g. your IAM user). These become EKS access entries with AmazonEKSClusterAdminPolicy."
  type        = list(string)
  default     = ["arn:aws:iam::986314681697:user/test"]
}
