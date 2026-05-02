# ==================== User Data ====================
# user_data is a small bootstrap stub (well under 16KB) that:
#   1. Exports config variables as environment variables
#   2. Downloads the full setup script from S3
#   3. Executes it
#
# The full setup script lives in scripts/setup.sh and is uploaded to S3
# via s3.tf — this sidesteps EC2's 16KB user_data hard limit.

locals {
  # Read the setup script from disk so Terraform can track changes and
  # upload a new S3 object when the script is modified.
  setup_script = file("${path.module}/scripts/setup.sh")

  user_data = <<-BOOTSTRAP
    #!/bin/bash
    exec > >(tee /var/log/openclaw-bootstrap.log) 2>&1
    echo "Bootstrap start: $(date)"

    # Export variables for setup.sh
    export STACK_NAME="${local.name_prefix}"
    export AWS_REGION="${var.aws_region}"
    export OPENCLAW_MODEL="${var.openclaw_model}"
    export OPENCLAW_VERSION="${var.openclaw_version}"
    export ENABLE_SANDBOX="${var.enable_sandbox}"
    export ENABLE_MONITORING="${var.enable_monitoring}"

    # Install AWS CLI (needed to fetch the script from S3)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q unzip curl
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$(arch).zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

    # Fetch and run the full setup script from S3
    aws s3 cp "s3://${aws_s3_bucket.scripts.id}/setup.sh" /opt/openclaw-setup.sh \
      --region "${var.aws_region}"
    chmod +x /opt/openclaw-setup.sh
    /opt/openclaw-setup.sh

    echo "Bootstrap complete: $(date)"
  BOOTSTRAP
}
