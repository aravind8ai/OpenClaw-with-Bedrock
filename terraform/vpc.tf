# ==================== VPC and Network ====================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "${local.name_prefix}-public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${local.name_prefix}-private-subnet-az1" }
}

# Second private subnet in a different AZ for VPC endpoint availability
# (bedrock-mantle may not be available in all AZs)
resource "aws_subnet" "private_az2" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "${local.name_prefix}-private-subnet-az2" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ==================== VPC Endpoint Security Group ====================

resource "aws_security_group" "vpce" {
  count       = var.create_vpc_endpoints ? 1 : 0
  name        = "${local.name_prefix}-vpce-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }

  tags = { Name = "${local.name_prefix}-vpce-sg" }
}

locals {
  vpce_subnet_ids = var.create_vpc_endpoints ? [
    aws_subnet.private.id,
    aws_subnet.private_az2[0].id,
  ] : []
  vpce_sg_ids = var.create_vpc_endpoints ? [aws_security_group.vpce[0].id] : []
}

# ==================== VPC Endpoints ====================

resource "aws_vpc_endpoint" "bedrock_runtime" {
  count               = var.create_vpc_endpoints ? 1 : 0
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.vpce_subnet_ids
  security_group_ids  = local.vpce_sg_ids
  tags                = { Name = "${local.name_prefix}-bedrock-runtime-vpce" }
}

resource "aws_vpc_endpoint" "bedrock_mantle" {
  count               = local.create_mantle_endpoint ? 1 : 0
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-mantle"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.vpce_subnet_ids
  security_group_ids  = local.vpce_sg_ids
  tags                = { Name = "${local.name_prefix}-bedrock-mantle-vpce" }
}

resource "aws_vpc_endpoint" "ssm" {
  count               = var.create_vpc_endpoints ? 1 : 0
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.vpce_subnet_ids
  security_group_ids  = local.vpce_sg_ids
  tags                = { Name = "${local.name_prefix}-ssm-vpce" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count               = var.create_vpc_endpoints ? 1 : 0
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.vpce_subnet_ids
  security_group_ids  = local.vpce_sg_ids
  tags                = { Name = "${local.name_prefix}-ssmmessages-vpce" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  count               = var.create_vpc_endpoints ? 1 : 0
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.vpce_subnet_ids
  security_group_ids  = local.vpce_sg_ids
  tags                = { Name = "${local.name_prefix}-ec2messages-vpce" }
}
