# =============================================================================
# Root Outputs — aggregated from all child modules
# =============================================================================

# ── Networking ────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB)"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS + RDS)"
  value       = module.vpc.private_subnet_ids
}

# ── EKS ───────────────────────────────────────────────────────────────────────
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.eks_cluster_name
}

output "eks_cluster_endpoint" {
  description = "Private EKS API server endpoint"
  value       = module.eks.eks_cluster_endpoint
  sensitive   = true
}

output "ecr_backend_url" {
  description = "ECR URL for backend image — use in K8s manifests and deploy workflow"
  value       = module.eks.ecr_backend_url
}

output "ecr_frontend_url" {
  description = "ECR URL for frontend image — use in K8s manifests and deploy workflow"
  value       = module.eks.ecr_frontend_url
}

output "app_irsa_role_arn" {
  description = "IRSA IAM Role ARN for backend pods — set as IRSA_ROLE_ARN in ecommerce-app repo secrets"
  value       = module.eks.app_irsa_role_arn
}

# ── RDS ───────────────────────────────────────────────────────────────────────
output "db_secret_arn" {
  description = "Secrets Manager ARN for DB credentials — set as DB_SECRET_ARN in ecommerce-app repo secrets"
  value       = module.rds.db_secret_arn
}

output "db_endpoint" {
  description = "RDS private endpoint (VPC-internal)"
  value       = module.rds.db_endpoint
  sensitive   = true
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────────
output "github_actions_infra_role_arn" {
  description = "Set as AWS_OIDC_ROLE_ARN in the infra-aws-eks repository secrets"
  value       = module.oidc_github.github_actions_infra_role_arn
}

output "github_actions_app_role_arn" {
  description = "Set as AWS_OIDC_ROLE_ARN in the ecommerce-app repository secrets"
  value       = module.oidc_github.github_actions_app_role_arn
}
