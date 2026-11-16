variable "service" {
  description = "Service name, used as a prefix for every resource (e.g. \"surge-links\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.service))
    error_message = "service must be 3-30 chars: lowercase letters, digits and dashes."
  }
}

variable "environment" {
  description = "Environment name. Drives safe defaults (prod gets Multi-AZ, deletion protection, longer backups)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the service VPC, /16 to /20. Split into 16 blocks: up to 3 public and 3 private subnets."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR between /16 and /20."
  }
}

variable "az_count" {
  description = "Number of availability zones (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (RDS subnet groups need at least 2 AZs)."
  }
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway instead of one per AZ. Cheaper; loses egress if that AZ fails. Defaults to true outside prod."
  type        = bool
  default     = null
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  description = "Initial storage in GB. Storage autoscaling grows it up to 5x."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage_gb >= 20 && var.db_allocated_storage_gb <= 1000
    error_message = "db_allocated_storage_gb must be between 20 and 1000."
  }
}

variable "db_engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "db_multi_az" {
  description = "Standby replica in another AZ. Defaults to true in prod, false elsewhere."
  type        = bool
  default     = null
}

variable "db_backup_retention_days" {
  description = "Automated backup / PITR window. Defaults to 14 in prod, 3 elsewhere."
  type        = number
  default     = null
}

variable "db_max_connections" {
  description = "Postgres max_connections. Size it against HPA max replicas x per-pod pool (docs/capacity.md) and instance memory (~10 MB per connection)."
  type        = number
  default     = 100
}

variable "db_app_user" {
  description = "Postgres user the pods log in as with IAM authentication (created once by scripts/db-bootstrap.sql)."
  type        = string
  default     = "app_user"
}

variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN of the EKS cluster the service runs in. Null skips the IRSA role."
  type        = string
  default     = null
}

variable "k8s_namespace" {
  description = "Kubernetes namespace of the service account allowed to assume the IRSA role."
  type        = string
  default     = "default"
}

variable "k8s_service_account" {
  description = "Kubernetes service account name allowed to assume the IRSA role. Defaults to the service name."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags merged into every resource (e.g. team, cost-center)."
  type        = map(string)
  default     = {}
}
