variable "project_name" {
  description = "Prefix for all resource names"
  default     = "taskflow"
}

variable "environment" {
  description = "Deployment environment"
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS nodes (both On-Demand and Spot groups)"
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "RDS instance class"
  default     = "db.t3.medium"
}

variable "db_username" {
  description = "RDS master username"
  sensitive   = true
}

variable "db_password" {
  description = "RDS master password — min 8 chars, no @ or % characters"
  sensitive   = true
}

variable "alert_email" {
  description = "Email for AWS Budget alerts"
  default     = "your@email.com"
}

variable "key_pair_name" {
  description = "EC2 Key Pair name for SSH — create with Step 0 commands before running Terraform"
  default     = "taskflow-key"
}
