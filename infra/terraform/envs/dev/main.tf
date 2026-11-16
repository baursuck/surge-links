module "surge_links" {
  source = "../../modules/service-env"

  service     = "surge-links"
  environment = "dev"
  vpc_cidr    = "10.20.0.0/16"
}

output "db_endpoint" {
  value = module.surge_links.db_endpoint
}

output "effective_settings" {
  value = module.surge_links.effective_settings
}
