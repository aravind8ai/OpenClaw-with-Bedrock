variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "This deployment is locked to us-east-1."
  }
}

variable "stack_name" {
  description = "Unique name prefix for all resources (equivalent to CloudFormation stack name)"
  type        = string
  default     = "openclaw-bedrock"
}

variable "openclaw_model" {
  description = "Bedrock model ID"
  type        = string
  default     = "global.amazon.nova-2-lite-v1:0"
  validation {
    condition = contains([
      "global.amazon.nova-2-lite-v1:0",
      "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
      "us.amazon.nova-pro-v1:0",
      "global.anthropic.claude-opus-4-6-v1",
      "global.anthropic.claude-opus-4-5-20251101-v1:0",
      "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      "global.anthropic.claude-sonnet-4-20250514-v1:0",
      "us.deepseek.r1-v1:0",
      "us.meta.llama3-3-70b-instruct-v1:0",
      "moonshotai.kimi-k2.5",
    ], var.openclaw_model)
    error_message = "Invalid Bedrock model ID."
  }
}

variable "openclaw_version" {
  description = "OpenClaw version to install"
  type        = string
  default     = "2026.3.24"
  validation {
    condition     = contains(["2026.3.24", "2026.4.5", "latest"], var.openclaw_version)
    error_message = "Must be 2026.3.24, 2026.4.5, or latest."
  }
}

variable "instance_type" {
  description = "EC2 instance type recommended"
  type        = string
  default     = "t2.micro"
  validation {
    condition = contains([
      "t2.micro",
      "t4g.small", "t4g.medium", "t4g.large", "t4g.xlarge",
      "c6g.large", "c6g.xlarge", "c7g.large", "c7g.xlarge",
      "r6g.medium", "r6g.large", "r6g.xlarge",
      "r7g.medium", "r7g.large", "r7g.xlarge",
      "t3.small", "t3.medium", "t3.large",
      "c5.xlarge", "r5.large", "r5.xlarge",
    ], var.instance_type)
    error_message = "Invalid instance type."
  }
}

variable "key_pair_name" {
  description = "EC2 key pair name for emergency SSH access. Leave empty to skip."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed for SSH (e.g. 1.2.3.4/32). Leave empty to disable SSH ingress."
  type        = string
  default     = ""
}

variable "create_vpc_endpoints" {
  description = "Create VPC endpoints for private Bedrock + SSM access (~$29/mo for 5 endpoints)"
  type        = bool
  default     = true
}

variable "enable_sandbox" {
  description = "Install Docker for sandboxed code execution"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Enable CloudWatch monitoring, health checks, and auto-recovery"
  type        = bool
  default     = true
}

variable "enable_data_protection" {
  description = "Retain the data EBS volume when resources are destroyed"
  type        = bool
  default     = false
}
