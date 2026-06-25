variable "project_name" {
  description = "Project name prefix."
  type        = string
}

variable "github_org" {
  description = "GitHub organisation name or personal account username."
  type        = string
}

variable "ecr_backend_arn" {
  description = "ECR backend repository ARN — scoped into the app role's push policy."
  type        = string
}

variable "ecr_frontend_arn" {
  description = "ECR frontend repository ARN — scoped into the app role's push policy."
  type        = string
}

variable "eks_cluster_arn" {
  description = "EKS cluster ARN — scoped into the app role's describe policy."
  type        = string
}
