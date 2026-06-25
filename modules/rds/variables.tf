variable "project_name" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the RDS instance will be deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the RDS subnet group."
  type        = list(string)
}

variable "eks_nodes_sg_id" {
  description = "Security group ID of the EKS worker nodes. Port 5432 will be opened from this SG only."
  type        = string
}

variable "app_irsa_role_name" {
  description = "Name of the IRSA IAM role (created by module/eks). The Secrets Manager read policy is attached here."
  type        = string
}

variable "db_name" {
  description = "Initial PostgreSQL database name."
  type        = string
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "db_allocated_storage_gb" {
  description = "Initial allocated storage (GB). Auto-scales up to 500 GB."
  type        = number
}
