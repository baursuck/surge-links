terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # One state per environment. S3 native locking (no DynamoDB table needed).
  backend "s3" {
    bucket       = "surge-links-tfstate-111111111111"
    key          = "surge-links/dev/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

# Each environment is a separate AWS account. Credentials come from the caller:
# in CI, GitHub OIDC assumes `terraform-deployer` in account 111111111111 (see
# bootstrap/aws-account and .github/workflows/terraform-plan.yml); locally, an AWS profile.
# The account id is a placeholder until a real account exists.
provider "aws" {
  region              = "eu-central-1"
  allowed_account_ids = ["111111111111"]

  default_tags {
    tags = {
      project     = "surge-links"
      environment = "dev"
      owner       = "platform"
    }
  }
}
