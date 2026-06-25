variable "project_name" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where EKS will be deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS worker nodes (no public IPs)."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs included in the cluster config (for ALB controller)."
  type        = list(string)
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
}

variable "eks_node_desired_size" {
  description = "Desired worker node count."
  type        = number
}

variable "eks_node_min_size" {
  description = "Minimum worker node count."
  type        = number
}

variable "eks_node_max_size" {
  description = "Maximum worker node count (cluster autoscaler)."
  type        = number
}

variable "eks_node_disk_size_gb" {
  description = "EBS root volume size (GB) per node."
  type        = number
}
