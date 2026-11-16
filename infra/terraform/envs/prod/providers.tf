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
    bucket       = "surge-links-tfstate-222222222222"
    key          = "surge-links/prod/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

# Each environment is a separate AWS account; CI assumes a role inside it.
# Placeholder account id: replace with a real one before the first apply.
provider "aws" {
  region = "eu-central-1"

  assume_role {
    role_arn     = "arn:aws:iam::222222222222ole/terraform-deployer"
    session_name = "surge-links-prod"
  }

  default_tags {
    tags = {
      project     = "surge-links"
      environment = "prod"
      owner       = "platform"
    }
  }
}
