output "github_actions_infra_role_arn" {
  description = "Set as the AWS_OIDC_ROLE_ARN secret in the infra-aws-eks repository."
  value       = aws_iam_role.github_infra.arn
}

output "github_actions_app_role_arn" {
  description = "Set as the AWS_OIDC_ROLE_ARN secret in the ecommerce-app repository."
  value       = aws_iam_role.github_app.arn
}
