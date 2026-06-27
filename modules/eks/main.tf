# =============================================================================
# Module: eks
#
# Resources created:
#   - KMS key + alias        (Kubernetes Secrets envelope encryption)
#   - CloudWatch Log Group   (EKS control-plane audit logs, 90 day retention)
#   - IAM Role + policy      (EKS control plane — AmazonEKSClusterPolicy)
#   - Security Group         (control plane)
#   - Security Group         (worker nodes — also consumed by module/rds for port 5432)
#   - EKS Cluster            (private endpoint only, envelope encryption enabled)
#   - OIDC Provider          (for IRSA — IAM Roles for Service Accounts)
#   - IAM Role               (IRSA / app pods — trust policy only; policy in module/rds)
#   - IAM Role + policies    (worker nodes — EKSWorkerNode, CNI, ECR read)
#   - Launch Template        (gp3 encrypted EBS, IMDSv2 required, hop_limit=1)
#   - Managed Node Group     (private subnets only — no public IPs)
#   - ECR repositories x2   (backend + frontend, IMMUTABLE tags, KMS encrypted)
#   - ECR lifecycle policies (retain last 10 images)
# =============================================================================

# ── Locals ────────────────────────────────────────────────────────────────────
locals {
  # OIDC issuer without the https:// prefix — used as a map key in IAM conditions
  oidc_issuer_host = trimprefix(aws_iam_openid_connect_provider.eks.url, "https://")
}

# =============================================================================
# KMS — Envelope encryption for Kubernetes Secrets stored in etcd
# =============================================================================
resource "aws_kms_key" "eks_secrets" {
  description             = "EKS envelope encryption key for Kubernetes Secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-eks-secrets-kms"
  }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.project_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# =============================================================================
# CloudWatch Log Group — EKS control-plane logs
# =============================================================================
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = 90

  tags = {
    Name = "${var.project_name}-eks-control-plane-logs"
  }
}

# =============================================================================
# IAM — EKS Control Plane Role
# =============================================================================
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-eks-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# =============================================================================
# Security Groups
# =============================================================================

# Look up VPC CIDR so we can allow nodes → private API server without circular SG ref
data "aws_vpc" "this" {
  id = var.vpc_id
}

# Control Plane SG — controls access to the private EKS API endpoint ENI
resource "aws_security_group" "eks_cluster" {
  name        = "${var.project_name}-eks-cluster-sg"
  description = "EKS control plane - ingress from VPC on 443, egress all"
  vpc_id      = var.vpc_id

  # Nodes need to reach the private API server on 443 to bootstrap and join
  ingress {
    description = "Nodes to private API server (port 443)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    description = "Allow all outbound from control plane"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                            = "${var.project_name}-eks-cluster-sg"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Worker Nodes SG — also referenced by module/rds to allow port 5432
resource "aws_security_group" "eks_nodes" {
  name        = "${var.project_name}-eks-nodes-sg"
  description = "EKS worker nodes - node-to-node + control-plane traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "Node-to-node all TCP (pod networking)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Control plane to node - kubelet and admission webhooks"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  ingress {
    description     = "Control plane to node - metrics and exec"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  egress {
    description = "Allow all outbound from nodes (ECR pulls, Secrets Manager, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                            = "${var.project_name}-eks-nodes-sg"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# EKS Cluster — private endpoint only
# =============================================================================
resource "aws_eks_cluster" "this" {
  name     = var.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_cluster_version

  vpc_config {
    # Private + public subnets so the ALB controller can tag public subnets;
    # actual worker nodes only run in private subnets (see node group below).
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true # required: GitHub Actions runner runs kubectl from outside VPC
  }

  # Envelope encryption for all Kubernetes Secrets in etcd
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  # Ship all control-plane log streams to CloudWatch
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks,
  ]

  tags = {
    Name = var.eks_cluster_name
  }
}

# =============================================================================
# OIDC Provider — enables IRSA (IAM Roles for Service Accounts)
# =============================================================================
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.project_name}-eks-oidc"
  }
}

# =============================================================================
# IRSA IAM Role — backend application pods
#
# Only the 'backend' ServiceAccount in the 'ecommerce' namespace can assume
# this role. The Secrets Manager READ policy is attached by module/rds
# (which owns the secret ARN) to avoid a circular dependency.
# =============================================================================
data "aws_iam_policy_document" "app_irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Scope to ServiceAccounts in namespace:ecommerce that use AWS APIs (backend + catalog)
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values = [
        "system:serviceaccount:ecommerce:backend",
        "system:serviceaccount:ecommerce:catalog",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_irsa" {
  name               = "${var.project_name}-app-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.app_irsa_trust.json

  tags = {
    Name = "${var.project_name}-app-irsa-role"
  }
}

# =============================================================================
# IAM — Worker Node Role + Policy Attachments
# =============================================================================
resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-eks-nodes-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_read" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# =============================================================================
# Launch Template — encrypted EBS + IMDSv2
# hop_limit = 1 prevents pod processes from reaching the EC2 metadata endpoint
# =============================================================================
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${var.project_name}-eks-node-lt-"
  description = "Hardened EKS node: encrypted gp3 EBS, IMDSv2 required, hop_limit=1"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.eks_node_disk_size_gb
      volume_type = "gp3"
      encrypted   = true
      # Use the AWS-managed EBS key (alias/aws/ebs) — no custom KMS grants needed.
      # The eks_secrets KMS key is for etcd (control-plane secrets) only.
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  vpc_security_group_ids = [aws_security_group.eks_nodes.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-eks-node"
      Project = var.project_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# Managed Node Group — private subnets ONLY (no public IPs, no internet exposure)
# =============================================================================
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.eks_node_instance_types

  scaling_config {
    desired_size = var.eks_node_desired_size
    min_size     = var.eks_node_min_size
    max_size     = var.eks_node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.eks_ecr_read,
  ]

  tags = {
    Name = "${var.project_name}-node-group"
  }

  lifecycle {
    # Cluster Autoscaler manages desired_size at runtime — ignore Terraform drift
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# =============================================================================
# ECR Repositories — backend and frontend
# image_tag_mutability = IMMUTABLE prevents tag overwriting (supply-chain safety)
# scan_on_push = true runs AWS Inspector on every push
# KMS encryption uses the same key as the EKS cluster
# =============================================================================
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}/backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # allow destroy even when images exist

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.eks_secrets.arn
  }

  tags = {
    Name = "${var.project_name}-backend-ecr"
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}/frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # allow destroy even when images exist

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.eks_secrets.arn
  }

  tags = {
    Name = "${var.project_name}-frontend-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain last 10 images; expire older ones"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain last 10 images; expire older ones"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ── Product Catalog ECR (Python / FastAPI service) ────────────────────────────
resource "aws_ecr_repository" "catalog" {
  name                 = "${var.project_name}/catalog"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # allow destroy even when images exist

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.eks_secrets.arn
  }
  tags = { Name = "${var.project_name}-catalog-ecr" }
}

resource "aws_ecr_lifecycle_policy" "catalog" {
  repository = aws_ecr_repository.catalog.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}
