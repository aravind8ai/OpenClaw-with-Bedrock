# ==================== S3 bucket for setup script ====================
# The full setup script exceeds EC2's 16KB user_data limit, so it is
# stored in S3 and fetched by a small bootstrap stub in user_data.

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "scripts" {
  bucket        = "${local.name_prefix}-scripts-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = merge(local.common_tags, { Name = "${local.name_prefix}-scripts" })
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scripts" {
  bucket = aws_s3_bucket.scripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "setup_script" {
  bucket  = aws_s3_bucket.scripts.id
  key     = "setup.sh"
  content = local.setup_script
  etag    = md5(local.setup_script)
}

resource "aws_iam_role_policy" "s3_scripts" {
  name = "S3ScriptsPolicy"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.scripts.arn}/setup.sh"
    }]
  })
}
