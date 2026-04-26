variable "project_name" {}
variable "environment"  {}
variable "aws_region"   {}
variable "vpc_cidr"     { default = "10.0.0.0/16" }

locals {
  az_count = 3
}

data "aws_availability_zones" "available" { state = "available" }

# ── VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.project_name}-${var.environment}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# ── Public subnets (1 per AZ) — ALB, NAT GW, Jenkins EC2
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                                           = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                                       = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}" = "shared"
  }
}

# ── Private subnets (1 per AZ) — EKS nodes, RDS
# We keep 3 AZs even with 1 NAT GW.
# Pod-to-pod and pod-to-RDS traffic is VPC-internal — unaffected by NAT GW.
# Only outbound internet routes through the single NAT GW.
resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name                                                           = "${var.project_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"                              = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}" = "shared"
  }
}

# ── Single Elastic IP + NAT Gateway (cost saving: ~$65/month vs 3 NAT GWs)
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # place in AZ-1 public subnet
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "${var.project_name}-nat" }
}

# ── Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

# Single private route table — all 3 AZs share the one NAT GW
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── VPC Flow Logs (security audit — required in most prod environments)
resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/aws/vpc/${var.project_name}-${var.environment}/flow-logs"
  retention_in_days = 30
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.project_name}-${var.environment}-flow-logs-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow"; Principal = { Service = "vpc-flow-logs.amazonaws.com" }; Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
  tags            = { Name = "${var.project_name}-vpc-flow-logs" }
}

# ── Outputs
output "vpc_id"             { value = aws_vpc.main.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "nat_gateway_ip"     { value = aws_eip.nat.public_ip }
