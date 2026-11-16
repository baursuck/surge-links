module "surge_links" {
  source = "../../modules/service-env"

  service            = "surge-links"
  environment        = "prod"
  vpc_cidr           = "10.40.0.0/16"
  db_instance_class  = "db.t4g.medium"
  db_max_connections = 300
  # eks_oidc_provider_arn = "arn:aws:iam::222222222222:oidc-provider/oidc.eks..."
}

output "db_endpoint" {
  value = module.surge_links.db_endpoint
}

output "effective_settings" {
  value = module.surge_links.effective_settings
}
