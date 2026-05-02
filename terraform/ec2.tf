# ==================== AMI Lookup ====================
# Resolves the latest Ubuntu 24.04 AMI for the target architecture dynamically.
# This avoids hardcoded AMI IDs that are region-specific and go stale.

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${local.instance_arch}/hvm/ebs-gp3/ami-id"
}

# ==================== EC2 Instance ====================

resource "aws_instance" "main" {
  ami                  = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type        = var.instance_type
  key_name             = var.key_pair_name != "" ? var.key_pair_name : null
  iam_instance_profile = aws_iam_instance_profile.instance.name
  monitoring           = var.enable_monitoring

  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = local.user_data

  tags = merge(local.common_tags, {
    Name                  = "${local.name_prefix}-instance"
    "openclaw:stack-name" = local.name_prefix
  })

  depends_on = [
    aws_iam_instance_profile.instance,
    aws_internet_gateway.main,
  ]
}

# ==================== CloudWatch Alarms ====================

resource "aws_cloudwatch_metric_alarm" "auto_recovery" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${local.name_prefix}-auto-recovery"
  alarm_description   = "Auto-recover EC2 instance on system status check failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.main.id }
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:recover"]
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${local.name_prefix}-instance-status"
  alarm_description   = "Reboot on instance status check failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.main.id }
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:reboot"]
}
