# ==================== Security Group ====================

resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-sg"
  description = "OpenClaw instance security group"
  vpc_id      = aws_vpc.main.id

  # SSH ingress — only created when both key pair and CIDR are provided
  dynamic "ingress" {
    for_each = (var.key_pair_name != "" && var.allowed_ssh_cidr != "") ? [1] : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.allowed_ssh_cidr]
      description = "SSH access (fallback)"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg" }
}
