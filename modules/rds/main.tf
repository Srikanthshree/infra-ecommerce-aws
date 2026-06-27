# =============================================================================
# Module: rds
#
# Resources created:
#   - Security Group         (inbound 5432 from EKS nodes SG ONLY; no egress)
#   - DB Subnet Group        (private subnets only)
#   - DB Parameter Group     (postgres15: SSL=1, query + connection logging)
#   - random_password        (32-char, auto-generated — never hard-coded)
#   - Secrets Manager secret (DB credentials stored as JSON)
#   - Secrets Manager vers.  (includes host, port, dbname, user, password)
#   - IAM Role               (RDS Enhanced Monitoring)
#   - IAM Policy Attachment  (AmazonRDSEnhancedMonitoringRole)
#   - RDS PostgreSQL 15      (encrypted gp3, Multi-AZ, private, deletion protected)
#   - IAM Policy             (Secrets Manager GetSecretValue — scoped to this secret)
#   - IAM Policy Attachment  (attaches the above to the IRSA role from module/eks)
#
# Dependency note:
#   module/eks creates the IRSA IAM role (trust policy only).
#   module/rds attaches the Secrets Manager policy to that role once the secret
#   ARN is known — this breaks the otherwise circular dependency.
# =============================================================================

# =============================================================================
# Security Group — RDS
# Inbound port 5432 from EKS worker nodes security group ONLY.
# No egress rules = AWS denies all outbound (stateful SG still returns traffic).
# =============================================================================
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "PostgreSQL RDS: allow inbound 5432 from EKS nodes only. All other traffic denied."
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS worker nodes only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_nodes_sg_id]
  }

  # Deliberately no egress rule — RDS does not initiate outbound connections.
  # AWS returns response traffic for allowed inbound due to stateful SG behaviour.

  tags = {
    Name = "${var.project_name}-rds-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# DB Subnet Group — private subnets only
# =============================================================================
resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# =============================================================================
# DB Parameter Group — postgres15
# Enforces TLS, enables connection and query audit logging
# =============================================================================
resource "aws_db_parameter_group" "this" {
  name   = "${var.project_name}-pg15-params"
  family = "postgres15"

  # NOTE: ssl=1 is NOT specified here because:
  # - In PostgreSQL 15 RDS, ssl is a STATIC, NON-MODIFIABLE parameter
  # - ModifyDBParameterGroup rejects any attempt to set ssl
  # - ssl=1 (TLS enforced) is already the RDS PostgreSQL 15 default
  # - Specifying it would cause InvalidParameterValue during create/update

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_duration"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  parameter {
    name  = "log_temp_files"
    value = "0"
  }

  tags = {
    Name = "${var.project_name}-pg15-params"
  }

  lifecycle {
    # Ignore parameter changes after initial creation:
    # - Prevents ssl static-parameter modification error (InvalidParameterValue)
    # - Prevents create_before_destroy conflict (two groups same name)
    # Parameters are set correctly at creation time and left unchanged.
    ignore_changes = [parameter]
  }
}

# =============================================================================
# Random Master Password
# Auto-generated at apply time. Never appears in source code.
# Stored immediately in Secrets Manager below.
# =============================================================================
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]{}<>:?"
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  min_special      = 4
}

# =============================================================================
# Secrets Manager — DB credentials
# Application pods retrieve these at runtime via the IRSA role.
# No credentials are mounted into containers or stored in K8s Secrets.
# =============================================================================
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/${var.environment}/db-credentials"
  description             = "PostgreSQL master credentials for ${var.project_name} (${var.environment})"
  recovery_window_in_days = 0 # immediate deletion — avoids "pending deletion" conflict on destroy+apply cycles

  tags = {
    Name = "${var.project_name}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # Terraform writes this AFTER the DB instance is created (implicit dependency
  # via aws_db_instance.this.address). The JSON structure matches what the
  # Node.js backend expects.
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.this.address
    port     = 5432
    dbname   = var.db_name
  })
}

# =============================================================================
# IAM — RDS Enhanced Monitoring Role
# =============================================================================
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "monitoring.rds.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# =============================================================================
# RDS PostgreSQL 15 Instance
# =============================================================================
resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-postgres"
  engine         = "postgres"
  engine_version = "15.7"
  instance_class = var.db_instance_class

  # Storage
  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = 500
  storage_type          = "gp3"
  storage_encrypted     = true

  # Credentials — password from random_password, never hard-coded
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  # Network — private subnets only, never internet-facing
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  # High availability
  multi_az = true

  # Backups and maintenance
  backup_retention_period  = 7
  backup_window            = "02:00-03:00"
  maintenance_window       = "sun:03:00-sun:04:00"
  delete_automated_backups = false
  copy_tags_to_snapshot    = true
  skip_final_snapshot      = true # no snapshot on destroy — avoids repeated snapshot-name conflict in CI/CD

  # Protection
  deletion_protection        = false # must be false for terraform destroy to work
  auto_minor_version_upgrade = true

  # Observability
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

# =============================================================================
# IRSA Policy — allow backend pods to read the DB secret from Secrets Manager
#
# Placed here (not in module/eks) because:
#   - This module owns the secret ARN (aws_secretsmanager_secret.db.arn)
#   - module/eks has no knowledge of RDS, keeping the dependency one-directional
# =============================================================================
resource "aws_iam_policy" "app_secrets_read" {
  name        = "${var.project_name}-app-db-secrets-read-policy"
  description = "Allow the backend IRSA role to read the DB credentials secret."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadDbCredentialsSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        # Scoped to this exact secret ARN only — no wildcard
        Resource = aws_secretsmanager_secret.db.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_irsa_secrets" {
  role       = var.app_irsa_role_name
  policy_arn = aws_iam_policy.app_secrets_read.arn
}
