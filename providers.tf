terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in S3 with DynamoDB locking.
  # The bucket and table must exist before running terraform init.
  # Values are intentionally left as variables; supply them via -backend-config 
  # or a backend.hcl file — never hard-code them here.
  backend "s3" {
    bucket         = "ecommerce-application-state-file"
    key            = "ecommerce/main/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "ecommerce-application-statefile"
  }
}

provider "aws" {
  region = var.aws_region

  # All resources inherit these tags automatically.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "infra-aws-eks"
    }
  }
}
