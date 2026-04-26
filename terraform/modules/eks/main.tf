variable "project_name"        {}
variable "environment"         {}
variable "vpc_id"              {}
variable "private_subnet_ids"  {}
variable "cluster_version"     { default = "1.30" }
variable "node_instance_type"  { default = "t3.medium" }

locals {
  cluster_name = "${var.project_name}-${var.environment}"
}

# ── EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow"; Principal = { Service = "eks.amazonaws.com" }; Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ── Worker Node IAM Role (shared by both node groups)
resource "aws_iam_role" "eks_nodes" {
  name = "${local.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow"; Principal = { Service = "ec2.amazonaws.com" }; Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker"     { policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy";        role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "node_cni"        { policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy";              role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "node_ecr"        { policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"; role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "node_ssm"        { policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore";       role = aws_iam_role.eks_nodes.name }
resource "aws_iam_role_policy_attachment" "node_cloudwatch"  { policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy";        role = aws_iam_role.eks_nodes.name }

# ── Security group for nodes
resource "aws_security_group" "nodes" {
  name        = "${local.cluster_name}-nodes-sg"
  description = "EKS worker nodes — all traffic within group"
  vpc_id      = var.vpc_id

  ingress {
    description = "Node-to-node all traffic"
    from_port   = 0; to_port = 0; protocol = "-1"; self = true
  }
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.cluster_name}-nodes-sg" }
}

# ── EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.nodes.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
  tags       = { Name = local.cluster_name }
}

# ── Node Group 1: SYSTEM (On-Demand)
# Runs: kube-system, ArgoCD, Prometheus, Grafana, ALB controller
# On-Demand because these must not be interrupted mid-operation
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-system-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"

  scaling_config { min_size = 1; max_size = 2; desired_size = 1 }
  update_config  { max_unavailable = 1 }

  labels = { role = "system"; node-type = "on-demand" }

  taint {
    key    = "dedicated"
    value  = "system"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
  tags = { Name = "${local.cluster_name}-system-ng" }
}

# ── Node Group 2: APP (Spot)
# Runs: taskflow-backend pods
# Multiple instance types = higher Spot pool availability = less interruption
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-app-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = ["t3.medium", "t3a.medium", "t3.large"]
  capacity_type   = "SPOT"

  scaling_config { min_size = 1; max_size = 4; desired_size = 1 }
  update_config  { max_unavailable = 1 }

  labels = { role = "app"; node-type = "spot" }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
  tags = { Name = "${local.cluster_name}-app-ng" }
}

# ── OIDC Provider — enables IRSA (IAM Roles for Service Accounts)
# Allows pods to assume IAM roles without node-level permissions
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "cluster_name"      { value = aws_eks_cluster.main.name }
output "cluster_endpoint"  { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"        { value = aws_eks_cluster.main.certificate_authority[0].data }
output "node_sg_id"        { value = aws_security_group.nodes.id }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
output "oidc_issuer_url"   { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
