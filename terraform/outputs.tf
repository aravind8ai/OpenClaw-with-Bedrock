# ==================== Outputs ====================

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.main.id
}

output "instance_architecture" {
  description = "Instance CPU architecture (amd64 or arm64)"
  value       = local.instance_arch
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "bedrock_model" {
  description = "Bedrock model in use"
  value       = var.openclaw_model
}

output "data_volume_id" {
  description = "EBS data volume ID"
  value       = aws_ebs_volume.data.id
}

output "ssm_port_forward_command" {
  description = "Run on your local machine to open the Web UI (keep terminal open)"
  value       = "aws ssm start-session --target ${aws_instance.main.id} --region ${var.aws_region} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"18789\"],\"localPortNumber\":[\"18789\"]}'"
}

output "get_token_command" {
  description = "Retrieve the gateway token from SSM Parameter Store"
  value       = "aws ssm get-parameter --name /openclaw/${local.name_prefix}/gateway-token --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"
}

output "web_ui_url" {
  description = "Web UI URL (after port forwarding is running)"
  value       = "http://localhost:18789/?token=<paste token here>"
}

output "monthly_cost_estimate" {
  description = "Estimated monthly cost (USD)"
  value = join("\n", [
    "EC2 (${var.instance_type}):     see https://aws.amazon.com/ec2/pricing/",
    "EBS (30GB x2 gp3):              ~$4.80",
    "VPC Endpoints:                  ${var.create_vpc_endpoints ? "~$29 (5 endpoints)" : "$0 (disabled)"}",
    "CloudWatch:                     ${var.enable_monitoring ? "~$4" : "$0 (disabled)"}",
    "Bedrock:                        pay-per-use",
  ])
}
