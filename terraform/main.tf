terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  name_prefix = var.stack_name

  # Common tags applied to all resources
  common_tags = {
    Project   = "openclaw"
    StackName = local.name_prefix
    ManagedBy = "terraform"
  }

  # Architecture lookup by instance family prefix
  instance_arch = can(regex("^(t4g|c6g|c7g|r6g|r7g)", var.instance_type)) ? "arm64" : "amd64"

  # Bedrock Mantle supported regions
  mantle_regions = toset([
    "us-east-1", "us-east-2", "us-west-2",
    "ap-southeast-3", "ap-south-1", "ap-northeast-1",
    "eu-central-1", "eu-west-1", "eu-west-2",
    "eu-south-1", "eu-north-1", "sa-east-1",
  ])
  create_mantle_endpoint = var.create_vpc_endpoints && contains(local.mantle_regions, var.aws_region)

  # Interface VPC endpoints to create (excluding bedrock-mantle which is region-conditional)
  vpc_endpoint_services = var.create_vpc_endpoints ? toset([
    "bedrock-runtime",
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]) : toset([])
}
