output "vpc_id" {
  description = "ID of the service VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnets (pods, database)."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnets (load balancers, NAT)."
  value       = aws_subnet.public[*].id
}

output "app_security_group_id" {
  description = "Attach to the service pods; it is the only source allowed into the database."
  value       = aws_security_group.app.id
}

output "db_endpoint" {
  description = "Postgres host:port."
  value       = aws_db_instance.this.endpoint
}

output "db_name" {
  description = "Database name."
  value       = aws_db_instance.this.db_name
}

output "db_app_user" {
  description = "Postgres user the pods connect as (IAM authentication, no password)."
  value       = var.db_app_user
}

output "db_secret_arn" {
  description = "Secrets Manager ARN with the master credentials (rotated by RDS). For admins and day-0 bootstrap only."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "app_role_arn" {
  description = "IAM role for the Kubernetes service account (null when IRSA is disabled)."
  value       = one(aws_iam_role.app[*].arn)
}

output "effective_settings" {
  description = "Resolved environment defaults, handy in plan output and reviews."
  value = {
    single_nat_gateway  = local.single_nat
    db_multi_az         = local.db_multi_az
    db_backup_retention = local.db_backup_retention
    deletion_protection = local.is_prod
  }
}
