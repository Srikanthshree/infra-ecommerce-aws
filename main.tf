# =============================================================================
# Root Module — Orchestrates all child modules
#
# Dependency chain (no circular refs):
#   vpc → eks → rds → (oidc_github depends on eks only)
#
#   module.vpc         : VPC, subnets, NAT GW, route tables, flow logs
#   module.eks         : EKS cluster, node group, ECR, IRSA role (trust only)
#   module.rds         : RDS PostgreSQL, Secrets Manager, IRSA policy attachment
#   module.oidc_github : GitHub Actions OIDC provider + IAM roles/policies 
# =============================================================================

module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  eks_cluster_name     = var.eks_cluster_name
  aws_region           = var.aws_region
}

module "eks" {
  source = "./modules/eks"

  project_name            = var.project_name
  environment             = var.environment
  eks_cluster_name        = var.eks_cluster_name
  eks_cluster_version     = var.eks_cluster_version
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  public_subnet_ids       = module.vpc.public_subnet_ids
  eks_node_instance_types = var.eks_node_instance_types
  eks_node_desired_size   = var.eks_node_desired_size
  eks_node_min_size       = var.eks_node_min_size
  eks_node_max_size       = var.eks_node_max_size
  eks_node_disk_size_gb   = var.eks_node_disk_size_gb
}

module "rds" {
  source = "./modules/rds"

  project_name            = var.project_name
  environment             = var.environment
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  eks_nodes_sg_id         = module.eks.eks_nodes_sg_id
  app_irsa_role_name      = module.eks.app_irsa_role_name
  db_name                 = var.db_name
  db_username             = var.db_username
  db_instance_class       = var.db_instance_class
  db_allocated_storage_gb = var.db_allocated_storage_gb
}
