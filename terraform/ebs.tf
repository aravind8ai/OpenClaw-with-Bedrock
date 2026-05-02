# ==================== Data Volume ====================

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = 30
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.common_tags, { Name = "${local.name_prefix}-data" })
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.main.id
  force_detach = true
}
