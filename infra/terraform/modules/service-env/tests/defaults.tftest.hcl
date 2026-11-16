# Plan-only tests with a mocked AWS provider: no credentials, no cost.
# Run: terraform init && terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:eu-central-1:111111111111:secret:rds!db-mock", kms_key_id = "", secret_status = "active" }]
    }
  }
}

variables {
  service     = "surge-links"
  environment = "dev"
}

run "dev_is_cheap_by_default" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "dev should use a single NAT gateway"
  }

  assert {
    condition     = aws_db_instance.this.multi_az == false
    error_message = "dev should not pay for Multi-AZ"
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == false && aws_db_instance.this.skip_final_snapshot == true
    error_message = "dev databases should be disposable"
  }
}

run "prod_is_safe_by_default" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "prod should have one NAT gateway per AZ"
  }

  assert {
    condition     = aws_db_instance.this.multi_az && aws_db_instance.this.deletion_protection
    error_message = "prod must be Multi-AZ with deletion protection"
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 14
    error_message = "prod must keep 14 days of backups"
  }
}

run "database_is_private_and_encrypted" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false && aws_db_instance.this.storage_encrypted
    error_message = "database must be private and encrypted"
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true
    error_message = "master password must live in Secrets Manager, not in state"
  }

  assert {
    condition     = aws_db_instance.this.iam_database_authentication_enabled == true
    error_message = "pods must be able to log in with IAM tokens instead of passwords"
  }
}

run "subnets_do_not_overlap" {
  command = plan

  variables {
    vpc_cidr = "10.30.0.0/20"
    az_count = 3
  }

  assert {
    condition     = length(setintersection(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block)) == 0
    error_message = "public and private subnets overlap"
  }

  assert {
    condition     = aws_subnet.private[2].cidr_block == "10.30.10.0/24"
    error_message = "unexpected private subnet layout"
  }
}

run "irsa_role_only_when_cluster_given" {
  command = plan

  assert {
    condition     = length(aws_iam_role.app) == 0
    error_message = "no IRSA role without an OIDC provider"
  }
}

run "irsa_role_created_for_cluster" {
  command = plan

  variables {
    eks_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.eu-central-1.amazonaws.com/id/ABC123"
    k8s_namespace         = "links"
  }

  assert {
    condition     = length(aws_iam_role.app) == 1 && length(aws_iam_role_policy.app_db_connect) == 1
    error_message = "IRSA role with rds-db:connect expected when an OIDC provider is given"
  }
}

run "rejects_bad_service_name" {
  command = plan

  variables {
    service = "Surge_Links"
  }

  expect_failures = [var.service]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}
