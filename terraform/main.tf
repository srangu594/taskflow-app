terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.50" }
    random = { source = "hashicorp/random", version = "~> 3.6"  }
    tls    = { source = "hashicorp/tls",    version = "~> 4.0"  }
  }

  # Remote state — create S3 bucket and DynamoDB table BEFORE running terraform apply
  # See Step 1 in the deployment guide for the exact commands.
  backend "s3" {
    bucket         = "taskflow-terraform-state-prod"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "taskflow-tf-locks"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ══════════════════════════════════════════════════════
# MODULE: VPC
# Creates: VPC, 3 public subnets, 3 private subnets,
#          1 NAT Gateway (cost-optimised), route tables,
#          VPC flow logs
# ══════════════════════════════════════════════════════
module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_cidr     = var.vpc_cidr
}

# ══════════════════════════════════════════════════════
# MODULE: EKS
# Creates: EKS cluster 1.30, two node groups:
#   - system (On-Demand t3.medium, min=1) → kube-system, ArgoCD, Prometheus
#   - app    (Spot t3.medium, min=1)      → taskflow backend pods
# Also creates: IAM roles, OIDC provider for IRSA
# ══════════════════════════════════════════════════════
module "eks" {
  source             = "./modules/eks"
  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  cluster_version    = "1.30"
  node_instance_type = var.node_instance_type
}

# ══════════════════════════════════════════════════════
# MODULE: RDS
# Creates: PostgreSQL 16, Single-AZ, db.t3.medium,
#          encrypted, 7-day backups, Performance Insights
# NOTE: deletion_protection = false so terraform destroy
#       works cleanly during weekly sessions.
#       Data is protected via final snapshot.
# ══════════════════════════════════════════════════════
module "rds" {
  source             = "./modules/rds"
  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  db_name            = "taskflow_db"
  db_username        = var.db_username
  db_password        = var.db_password
  instance_class     = var.db_instance_class
  eks_sg_id          = module.eks.node_sg_id
}

# ══════════════════════════════════════════════════════
# MODULE: S3 + CloudFront
# Creates: S3 bucket for React frontend,
#          CloudFront CDN distribution,
#          artifacts bucket for Jenkins
# ══════════════════════════════════════════════════════
module "s3" {
  source       = "./modules/s3"
  project_name = var.project_name
  environment  = var.environment
}

# ══════════════════════════════════════════════════════
# ECR Repositories
# Created here (not in a module) because they are
# referenced by Jenkins, GitHub Actions, and K8s.
# ══════════════════════════════════════════════════════
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

# Keep only last 20 images — prevents ECR storage bill creep
resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection    = { tagStatus = "any"; countType = "imageCountMoreThan"; countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection    = { tagStatus = "any"; countType = "imageCountMoreThan"; countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# ══════════════════════════════════════════════════════
# Jenkins Security Group
# Created by Terraform so you can SELECT it when
# launching Jenkins EC2 manually (Step 5 in guide).
# Jenkins EC2 itself is NOT managed by Terraform.
# ══════════════════════════════════════════════════════
resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins CI server — HTTP, SSH"
  vpc_id      = module.vpc.vpc_id

  # Jenkins UI — from anywhere (required for GitHub webhook delivery)
  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — from anywhere for initial setup
  # After setup: narrow this to your IP: "<your-ip>/32"
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound — Jenkins needs to reach ECR, EKS, GitHub, AWS APIs
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-jenkins-sg" }
}

# ══════════════════════════════════════════════════════
# IAM Role for Jenkins EC2 Instance Profile
# Allows Jenkins to push to ECR, manage EKS, sync S3,
# invalidate CloudFront — without static IAM user keys.
# Attach this profile when launching Jenkins EC2.
# ══════════════════════════════════════════════════════
resource "aws_iam_role" "jenkins_ec2" {
  name = "${var.project_name}-jenkins-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_permissions" {
  name = "${var.project_name}-jenkins-permissions"
  role = aws_iam_role.jenkins_ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR: authenticate, push, pull images
        Sid    = "ECR"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = "*"
      },
      {
        # EKS: update kubeconfig, describe cluster
        Sid    = "EKS"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi",
        ]
        Resource = "*"
      },
      {
        # S3: sync frontend build artifacts
        Sid    = "S3"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = "*"
      },
      {
        # CloudFront: invalidate cache after frontend deploy
        Sid    = "CloudFront"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:ListDistributions",
        ]
        Resource = "*"
      },
      {
        # Terraform: read state only (Jenkins runs plan, not apply)
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = [
          "arn:aws:s3:::taskflow-terraform-state-prod",
          "arn:aws:s3:::taskflow-terraform-state-prod/*",
          "arn:aws:dynamodb:${var.aws_region}:*:table/taskflow-tf-locks",
        ]
      },
      {
        # STS: needed by AWS CLI for assumed roles
        Sid      = "STS"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins_ec2.name
}

# ══════════════════════════════════════════════════════
# AWS Budget Alert
# Alerts via email when monthly spend exceeds $25.
# At 6hrs/week your spend is ~$9/month so this alert
# fires ONLY if something is left running accidentally.
# ══════════════════════════════════════════════════════
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "25"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ══════════════════════════════════════════════════════
# OUTPUTS
# These values are needed in later deployment steps.
# Run: terraform output   after apply completes.
# ══════════════════════════════════════════════════════
output "cluster_name" {
  description = "EKS cluster name — used in aws eks update-kubeconfig"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  description = "RDS host:port — used to build DATABASE_URL for K8s secret and Jenkins credential"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "RDS port (always 5432 for PostgreSQL)"
  value       = module.rds.port
}

output "ecr_backend_url" {
  description = "ECR URL for backend image — used in docker push and K8s deployment manifest"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  description = "ECR URL for frontend image"
  value       = aws_ecr_repository.frontend.repository_url
}

output "s3_frontend_bucket" {
  description = "S3 bucket name — used in aws s3 sync and GitHub Actions secret S3_FRONTEND_BUCKET"
  value       = module.s3.bucket_name
}

output "cloudfront_url" {
  description = "CloudFront HTTPS URL — your frontend URL"
  value       = module.s3.cloudfront_url
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — used for cache invalidation"
  value       = module.s3.cloudfront_distribution_id
}

output "vpc_id" {
  description = "VPC ID — needed when launching Jenkins EC2 manually"
  value       = module.vpc.vpc_id
}

output "public_subnet_id" {
  description = "First public subnet ID — launch Jenkins EC2 here (has internet access)"
  value       = module.vpc.public_subnet_ids[0]
}

output "jenkins_security_group_id" {
  description = "Security group ID for Jenkins EC2 — select this when launching the instance"
  value       = aws_security_group.jenkins.id
}

output "jenkins_iam_instance_profile" {
  description = "IAM instance profile name — attach to Jenkins EC2 for AWS permissions"
  value       = aws_iam_instance_profile.jenkins.name
}

output "database_url" {
  description = "Full DATABASE_URL for K8s secret (replace db_password placeholder)"
  value       = "postgresql://${var.db_username}:YOURPASSWORD@${module.rds.endpoint}/taskflow_db"
  sensitive   = false
}
