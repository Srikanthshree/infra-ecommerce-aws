# =============================================================================
# Module: oidc_github
# Configures AWS to trust short-lived OIDC tokens from GitHub Actions runners.
# No static IAM access keys are ever created.
#
# Creates:
#   AWS IAM OIDC Identity Provider for token.actions.githubusercontent.com
#   IAM Role — infra-aws-eks repo  (Terraform full-lifecycle)
#   IAM Role — ecommerce-app repo  (ECR push + EKS describe)
#   IAM Policies with least-privilege, resource-scoped where possible
# =============================================================================

# ── TLS Thumbprint (auto-refreshed on every apply) ────────────────────────────
data "tls_certificate" "github_oidc" {
  url = "https://token.actions.githubusercontent.com"
}

# ── GitHub OIDC Identity Provider ────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_oidc.certificates[0].sha1_fingerprint]
  tags            = { Name = "${var.project_name}-github-oidc-provider" }
}

# ── IAM Role — infra-aws-eks repo ────────────────────────────────────────────
resource "aws_iam_role" "github_infra" {
  name                 = "${var.project_name}-github-infra-role"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GitHubOIDCInfra"
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Strictly scoped to the infra-aws-eks repository only
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/infra-aws-eks:*"
        }
      }
    }]
  })

  tags = { Name = "${var.project_name}-github-infra-role" }
}

# ── IAM Role — ecommerce-app repo ────────────────────────────────────────────
resource "aws_iam_role" "github_app" {
  name                 = "${var.project_name}-github-app-role"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GitHubOIDCApp"
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Strictly scoped to the ecommerce-app repository only
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/ecommerce-app:*"
        }
      }
    }]
  })

  tags = { Name = "${var.project_name}-github-app-role" }
}

# ── Policy — infra role (Terraform operations) ────────────────────────────────
resource "aws_iam_policy" "github_infra" {
  name        = "${var.project_name}-github-infra-policy"
  description = "Least-privilege permissions for Terraform to manage EKS, VPC, RDS, KMS, IAM, and ECR."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2VPC"
        Effect = "Allow"
        Action = ["ec2:*"]
        Resource = "*"
      },
      {
        Sid    = "EKS"
        Effect = "Allow"
        Action = ["eks:*"]
        Resource = "*"
      },
      {
        Sid    = "RDS"
        Effect = "Allow"
        Action = ["rds:*"]
        Resource = "*"
      },
      {
        Sid    = "SecretsManager"
        Effect = "Allow"
        Action = ["secretsmanager:*"]
        Resource = "*"
      },
      {
        Sid    = "KMS"
        Effect = "Allow"
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion", "kms:Tag*", "kms:CreateAlias",
          "kms:DeleteAlias", "kms:UpdateAlias",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole",
          "iam:UpdateRole", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:UntagRole",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
          "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:TagOpenIDConnectProvider",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = "*"
      },
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketVersioning",
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable",
        ]
        Resource = "*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:*", "cloudwatch:*"]
        Resource = "*"
      },
      {
        Sid    = "ECR"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository", "ecr:DeleteRepository",
          "ecr:DescribeRepositories", "ecr:PutLifecyclePolicy",
          "ecr:GetLifecyclePolicy", "ecr:PutImageScanningConfiguration",
          "ecr:TagResource", "ecr:GetRepositoryPolicy",
          "ecr:SetRepositoryPolicy", "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
    ]
  })
}

# ── Policy — app role (ECR push + EKS describe — resource-scoped) ─────────────
resource "aws_iam_policy" "github_app" {
  name        = "${var.project_name}-github-app-policy"
  description = "Permissions for the app CI/CD pipeline: push images to ECR and deploy to EKS."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage", "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
          "ecr:PutImage", "ecr:DescribeRepositories",
          "ecr:ListImages", "ecr:TagResource",
        ]
        # Scoped to only the two ECR repos provisioned by module/eks
        Resource = [var.ecr_backend_arn, var.ecr_frontend_arn]
      },
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = ["eks:DescribeCluster", "eks:ListClusters"]
        # Scoped to only the single EKS cluster
        Resource = var.eks_cluster_arn
      },
    ]
  })
}

# ── Policy Attachments ────────────────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "github_infra" {
  role       = aws_iam_role.github_infra.name
  policy_arn = aws_iam_policy.github_infra.arn
}

resource "aws_iam_role_policy_attachment" "github_app" {
  role       = aws_iam_role.github_app.name
  policy_arn = aws_iam_policy.github_app.arn
}
