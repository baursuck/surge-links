data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name    = "${var.service}-${var.environment}"
  is_prod = var.environment == "prod"
  azs     = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Safe-by-default: callers only override what they really need.
  single_nat          = coalesce(var.single_nat_gateway, !local.is_prod)
  db_multi_az         = coalesce(var.db_multi_az, local.is_prod)
  db_backup_retention = coalesce(var.db_backup_retention_days, local.is_prod ? 14 : 3)
  service_account     = coalesce(var.k8s_service_account, var.service)

  # Split the VPC into 16 equal blocks: public subnets take blocks 0..2, private 8..10.
  # /16 VPC -> /20 subnets (4096 IPs each), /20 VPC -> /24 subnets.
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  tags = merge(var.tags, {
    service     = var.service
    environment = var.environment
    managed-by  = "terraform"
  })
}

# ---------------------------------------------------------------- network

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags = merge(local.tags, {
    Name                     = "${local.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]
  tags = merge(local.tags, {
    Name                              = "${local.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_eip" "nat" {
  count  = local.single_nat ? 1 : var.az_count
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.single_nat ? 1 : var.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count                  = var.az_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.single_nat ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --------------------------------------------------------------- security

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Pods of ${var.service} (attach via SecurityGroupPolicy or node group)"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${local.name}-app" })
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Outbound to DB, AWS APIs and the internet via NAT"
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "Postgres for ${var.service}: only reachable from the app security group"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${local.name}-db" })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from app pods only"
}

# --------------------------------------------------------------- database

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_db_parameter_group" "this" {
  # name_prefix + create_before_destroy: a major-version change creates the new group
  # before the old one is detached, instead of failing on "group in use".
  name_prefix = "${local.name}-pg${var.db_engine_version}-"
  family      = "postgres${var.db_engine_version}"
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }

  parameter {
    name         = "max_connections"
    value        = tostring(var.db_max_connections)
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "250" # log queries slower than 250 ms
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = replace(var.service, "-", "_")
  username = "dbadmin"
  # Master password is generated and rotated by RDS in Secrets Manager: never in state.
  # Only humans and the day-0 bootstrap use it; pods log in as db_app_user via IAM auth.
  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_allocated_storage_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = local.db_multi_az

  backup_retention_period   = local.db_backup_retention
  backup_window             = "20:00-21:00" # 01:00-02:00 Almaty
  maintenance_window        = "sun:21:00-sun:22:00"
  copy_tags_to_snapshot     = true
  deletion_protection       = local.is_prod
  skip_final_snapshot       = !local.is_prod
  final_snapshot_identifier = local.is_prod ? "${local.name}-final" : null

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  auto_minor_version_upgrade            = true
  apply_immediately                     = !local.is_prod

  tags = local.tags
}

# ------------------------------------------------- IRSA role for the pods

data "aws_iam_policy_document" "irsa_trust" {
  count = var.eks_oidc_provider_arn == null ? 0 : 1

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:${local.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

locals {
  # arn:aws:iam::123:oidc-provider/oidc.eks.region.amazonaws.com/id/XYZ -> oidc.eks.../id/XYZ
  oidc_issuer = var.eks_oidc_provider_arn == null ? "" : element(split("oidc-provider/", var.eks_oidc_provider_arn), 1)
}

resource "aws_iam_role" "app" {
  count              = var.eks_oidc_provider_arn == null ? 0 : 1
  name               = "${local.name}-app"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[0].json
  tags               = local.tags
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Pods get a 15-minute IAM token instead of a password: nothing to rotate, nothing to leak.
data "aws_iam_policy_document" "db_connect" {
  statement {
    sid     = "ConnectAsAppUserOnly"
    actions = ["rds-db:connect"]
    resources = [
      "arn:aws:rds-db:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.this.resource_id}/${var.db_app_user}"
    ]
  }
}

resource "aws_iam_role_policy" "app_db_connect" {
  count  = var.eks_oidc_provider_arn == null ? 0 : 1
  name   = "rds-iam-connect"
  role   = aws_iam_role.app[0].id
  policy = data.aws_iam_policy_document.db_connect.json
}
