# Run once per AWS account: lets GitHub Actions assume a role via OIDC,
# so CI never stores long-lived AWS keys.

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
  description = "owner/repo allowed to assume the role."
  type        = string
}

variable "environment" {
  description = "GitHub environment name allowed to apply (protected with required reviewers)."
  type        = string
}

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

    # Only jobs bound to the protected GitHub environment can apply.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "terraform_deployer" {
  name                 = "terraform-deployer"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Broad on purpose for a demo; in a real platform this is a scoped policy plus a permissions boundary.
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.terraform_deployer.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

output "role_arn" {
  value = aws_iam_role.terraform_deployer.arn
}
