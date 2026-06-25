output "db_secret_arn" {
  description = "Secrets Manager ARN for DB credentials — set as DB_SECRET_ARN in the ecommerce-app repo secrets"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_endpoint" {
  description = "RDS private endpoint (reachable only within the VPC)"
  value       = aws_db_instance.this.address
  sensitive   = true
}
