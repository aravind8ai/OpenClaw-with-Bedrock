# Remote state backend — configured at runtime via -backend-config flags in CI.
# For local use, run:
#   terraform init \
#     -backend-config="bucket=<your-state-bucket>" \
#     -backend-config="key=openclaw/terraform.tfstate" \
#     -backend-config="region=us-west-2"
#
# To use local state instead (no S3 bucket needed), delete this file.

terraform {
  backend "s3" {}
}
