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
  region = var.aws_region
}

locals {
  name_prefix = var.stack_name

  # Architecture lookup — mirrors CloudFormation ArchitectureMap
  arch_map = {
    "t2.micro"   = "amd64"
    "t3.small"   = "amd64"
    "t3.medium"  = "amd64"
    "t3.large"   = "amd64"
    "t3.xlarge"  = "amd64"
    "c5.xlarge"  = "amd64"
    "r5.large"   = "amd64"
    "r5.xlarge"  = "amd64"
    "t4g.small"  = "arm64"
    "t4g.medium" = "arm64"
    "t4g.large"  = "arm64"
    "t4g.xlarge" = "arm64"
    "c6g.large"  = "arm64"
    "c6g.xlarge" = "arm64"
    "c7g.large"  = "arm64"
    "c7g.xlarge" = "arm64"
    "r6g.medium" = "arm64"
    "r6g.large"  = "arm64"
    "r6g.xlarge" = "arm64"
    "r7g.medium" = "arm64"
    "r7g.large"  = "arm64"
    "r7g.xlarge" = "arm64"
  }

  instance_arch = local.arch_map[var.instance_type]

  # Bedrock Mantle supported regions
  mantle_regions = toset([
    "us-east-1", "us-east-2", "us-west-2",
    "ap-southeast-3", "ap-south-1", "ap-northeast-1",
    "eu-central-1", "eu-west-1", "eu-west-2",
    "eu-south-1", "eu-north-1", "sa-east-1",
  ])
  create_mantle_endpoint = var.create_vpc_endpoints && contains(local.mantle_regions, var.aws_region)
}
