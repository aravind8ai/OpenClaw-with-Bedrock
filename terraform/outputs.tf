output "step1_install_ssm_plugin" {
  description = "STEP 1: Install SSM Session Manager Plugin on your local computer"
  value       = "https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
}

output "step2_port_forwarding" {
  description = "STEP 2: Run this command on your LOCAL computer (keep terminal open)"
  value       = "aws ssm start-session --target ${aws_instance.main.id} --region ${var.aws_region} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"18789\"],\"localPortNumber\":[\"18789\"]}'"
}

output "step3_get_token" {
  description = "STEP 3: Retrieve your access token from SSM Parameter Store"
  value       = "aws ssm get-parameter --name /openclaw/${local.name_prefix}/gateway-token --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"
}

output "step4_access_url" {
  description = "STEP 4: Open in browser (replace <token> with value from Step 3)"
  value       = "http://localhost:18789/?token=<token>"
}

output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.main.id
}

output "instance_architecture" {
  description = "Instance CPU architecture"
  value       = local.instance_arch
}

output "bedrock_model" {
  description = "Bedrock model in use"
  value       = var.openclaw_model
}

output "data_volume_id" {
  description = "EBS data volume ID"
  value       = aws_ebs_volume.data.id
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "monthly_cost_estimate" {
  description = "Estimated monthly cost (USD)"
  value = join("\n", [
    "EC2 (${var.instance_type}): see https://aws.amazon.com/ec2/pricing/",
    "EBS (30GB x2 gp3): ~$4.80",
    "VPC Endpoints: ${var.create_vpc_endpoints ? "~$29 (5 endpoints @ $0.01/hr)" : "$0 (disabled)"}",
    "CloudWatch: ${var.enable_monitoring ? "~$4" : "$0 (disabled)"}",
    "Bedrock: pay-per-use",
  ])
}
