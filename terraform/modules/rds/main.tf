variable "project_name"       {}
variable "environment"        {}
variable "vpc_id"             {}
variable "private_subnet_ids" {}
variable "db_name"            {}
variable "db_username"        { sensitive = true }
variable "db_password"        { sensitive = true }
variable "instance_class"     { default = "db.t3.medium" }
variable "eks_sg_id"          {}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${var.project_name}-db-subnet-group" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "RDS PostgreSQL — EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_sg_id]
  }
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-rds-sg" }
}

# Parameter group tuned for db.t3.medium (4 GB RAM)
# shared_buffers = 25% of RAM = 1 GB = 131072 × 8KB blocks
resource "aws_db_parameter_group" "postgres" {
  family = "postgres16"
  name   = "${var.project_name}-${var.environment}-pg16"

  parameter { name = "max_connections";             value = "150"    }
  parameter { name = "shared_buffers";              value = "131072" }
  parameter { name = "effective_cache_size";        value = "393216" }
  parameter { name = "work_mem";                    value = "4096"   }
  parameter { name = "log_min_duration_statement";  value = "1000"   }
  parameter { name = "log_connections";             value = "1"      }
  parameter { name = "log_disconnections";          value = "1"      }
  parameter { name = "log_lock_waits";              value = "1"      }

  tags = { Name = "${var.project_name}-pg16-params" }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-${var.environment}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow"; Principal = { Service = "monitoring.rds.amazonaws.com" }; Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
  role       = aws_iam_role.rds_monitoring.name
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.project_name}-${var.environment}-db"
  engine         = "postgres"
  engine_version = "16.2"
  instance_class = var.instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false

  multi_az = false   # Single-AZ: saves ~$52/month. 60s failover risk acceptable for personal project.

  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "Sun:04:00-Sun:05:00"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false

  # deletion_protection = false allows terraform destroy to work cleanly.
  # Data is still protected: skip_final_snapshot = false creates a manual
  # snapshot before the instance is deleted. That snapshot persists after destroy.
  deletion_protection       = false
  skip_final_snapshot       = false
  # Static identifier — no timestamp() which causes plan drift on every run
  final_snapshot_identifier = "${var.project_name}-${var.environment}-final-snapshot"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = { Name = "${var.project_name}-${var.environment}-rds" }
}

output "endpoint"    { value = aws_db_instance.postgres.endpoint }
output "port"        { value = aws_db_instance.postgres.port }
output "db_name"     { value = aws_db_instance.postgres.db_name }
output "db_username" { value = aws_db_instance.postgres.username; sensitive = true }
output "sg_id"       { value = aws_security_group.rds.id }
