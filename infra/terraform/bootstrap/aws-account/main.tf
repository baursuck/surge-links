# Day-0 setup, applied once per AWS account by an admin (local state, then migrate it into
# the bucket it creates). Creates:
#   - the S3 bucket for Terraform state (versioned, encrypted, private)
#   - GitHub OIDC trust, so CI never stores long-lived AWS keys
#   - terraform-deployer: plan-only from any PR, apply only from the protected environment

terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "github_repository" {
  description = "owner/repo allowed to assume the role, e.g. baursuck/surge-links."
  type        = string
}

variable "environment" {
  description = "Environment this account hosts (dev or prod); also the GitHub environment name."
  type        = string
}

variable "service" {
  description = "Service prefix the deployer may create IAM roles for."
  type        = string
  default     = "surge-links"
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------ state bucket

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.service}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Own KMS key (not the AWS-managed one): key policy and CloudTrail decide who can read state.
resource "aws_kms_key" "tfstate" {
  description         = "Terraform state for ${var.service}"
  enable_key_rotation = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------ GitHub OIDC

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Jobs bound to the protected GitHub environment (apply, needs a reviewer)
    # and pull-request jobs (plan only, enforced in the workflow).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:environment:${var.environment}",
        "repo:${var.github_repository}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "terraform_deployer" {
  name                 = "terraform-deployer"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Network and database resources the service-env module manages.
data "aws_iam_policy_document" "deployer" {
  statement {
    sid = "ServiceInfra"
    actions = [
      "ec2:*Vpc*", "ec2:*Subnet*", "ec2:*Route*", "ec2:*InternetGateway*",
      "ec2:*NatGateway*", "ec2:*Address*", "ec2:*SecurityGroup*", "ec2:*Tags",
      "ec2:Describe*",
      "rds:*",
      "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # IAM only for the service's own pod roles, never for anything else in the account.
  statement {
    sid = "OwnPodRolesOnly"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:GetRolePolicy",
      "iam:DeleteRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.service}-*"]
  }

  statement {
    sid       = "RdsServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["rds.amazonaws.com"]
    }
  }

  statement {
    sid       = "State"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
  }

  statement {
    sid       = "StateKey"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.tfstate.arn]
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "service-env"
  role   = aws_iam_role.terraform_deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}

output "role_arn" {
  value = aws_iam_role.terraform_deployer.arn
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
