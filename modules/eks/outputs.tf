output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  description = "Private EKS API server endpoint (VPC-internal only)"
  value       = aws_eks_cluster.this.endpoint
  sensitive   = true
}

output "eks_cluster_arn" {
  description = "EKS cluster ARN — passed to module/oidc_github for scoped IAM policies"
  value       = aws_eks_cluster.this.arn
}

output "eks_nodes_sg_id" {
  description = "Security group ID of EKS worker nodes — passed to module/rds for port 5432 ingress"
  value       = aws_security_group.eks_nodes.id
}

output "app_irsa_role_arn" {
  description = "IRSA IAM Role ARN for backend pods — annotate the K8s ServiceAccount with this"
  value       = aws_iam_role.app_irsa.arn
}

output "app_irsa_role_name" {
  description = "IRSA IAM Role name — used by module/rds to attach the Secrets Manager policy"
  value       = aws_iam_role.app_irsa.name
}

output "ecr_backend_url" {
  description = "ECR repository URL for the backend image"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  description = "ECR repository URL for the frontend image"
  value       = aws_ecr_repository.frontend.repository_url
}

output "ecr_backend_arn" {
  description = "ECR backend repository ARN — passed to module/oidc_github for push policy"
  value       = aws_ecr_repository.backend.arn
}

output "ecr_frontend_arn" {
  description = "ECR frontend repository ARN — passed to module/oidc_github for push policy"
  value       = aws_ecr_repository.frontend.arn
}
