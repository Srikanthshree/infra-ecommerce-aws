# =============================================================================
# Module: vpc
# Network topology — fully private EKS, no NAT Gateway (cost optimised):
#   3 public  subnets  → ALB only (needs IGW for inbound public traffic)
#   3 private subnets  → EKS worker nodes + RDS (no public IPs, no NAT)
#   Internet Gateway   → ALB public access only
#   NO NAT Gateway     → replaced by VPC Interface + Gateway Endpoints
#   VPC Endpoints      → ECR, S3, STS, EC2, Logs, Secrets Manager, ELB
#   VPC Flow Logs      → CloudWatch (90-day retention)
#
# Why no NAT Gateway?
#   NAT GW costs ~$45/month + data processing fees.
#   VPC endpoints let private nodes reach AWS APIs without internet.
# =============================================================================

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                            = "${var.project_name}-vpc"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

# # ── Internet Gateway ──────────────────────────────────────────────────────────
# resource "aws_internet_gateway" "this" {
#   vpc_id = aws_vpc.this.id
#   tags   = { Name = "${var.project_name}-igw" }
# }

# ── Public Subnets (ALB only) ─────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # No auto public IP

  tags = {
    Name                                            = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

# ── Private Subnets (EKS nodes + RDS) ────────────────────────────────────────
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                                            = "${var.project_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
  }
}

# ── NAT Gateway REMOVED — replaced by VPC endpoints below ────────────────────

# ── Route Tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  # No 0.0.0.0/0 route — private nodes use VPC endpoints, not NAT/internet
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── VPC Flow Logs ─────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/flowlogs/${var.project_name}"
  retention_in_days = 90
  tags              = { Name = "${var.project_name}-vpc-flow-logs" }
}

resource "aws_iam_role" "flow_log" {
  name = "${var.project_name}-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.project_name}-vpc-flow-log-policy"
  role = aws_iam_role.flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id
  tags            = { Name = "${var.project_name}-vpc-flow-log" }
}

# =============================================================================
# VPC Endpoints — replace NAT Gateway for private subnet → AWS API access
#
# Without NAT, EKS worker nodes need endpoints to reach:
#   ECR       → pull container images
#   S3        → ECR stores image layers in S3 (free gateway endpoint)
#   STS       → IRSA assumes IAM roles via web identity
#   EC2       → EKS node bootstrapping (describe instances, etc.)
#   Logs      → CloudWatch log shipping from nodes
#   SecretsMgr→ app reads DB credentials at runtime
#   ELB       → ALB Ingress Controller creates/manages load balancers
# =============================================================================

# ── Security Group: allow HTTPS from within VPC ───────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "Allow HTTPS (443) inbound from VPC CIDR to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vpc-endpoints-sg" }
}

# ── S3 Gateway Endpoint (FREE — no hourly charge) ────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = { Name = "${var.project_name}-s3-endpoint" }
}

# ── Interface Endpoints (one per service, deployed in all private subnets) ────
locals {
  interface_endpoints = {
    "ecr-api"              = "com.amazonaws.${var.aws_region}.ecr.api"
    "ecr-dkr"              = "com.amazonaws.${var.aws_region}.ecr.dkr"
    "sts"                  = "com.amazonaws.${var.aws_region}.sts"
    "ec2"                  = "com.amazonaws.${var.aws_region}.ec2"
    "logs"                 = "com.amazonaws.${var.aws_region}.logs"
    "secretsmanager"       = "com.amazonaws.${var.aws_region}.secretsmanager"
    "elasticloadbalancing" = "com.amazonaws.${var.aws_region}.elasticloadbalancing"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true # resolve *.amazonaws.com → endpoint IP, not internet

  tags = { Name = "${var.project_name}-${each.key}-endpoint" }
}
