terraform {
  backend "s3" {
    bucket  = "amz-aidevops-470226123391-us-east-1-an"
    key     = "openclaw-agent/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

