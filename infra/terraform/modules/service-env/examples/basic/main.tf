# Minimal "golden path" usage: everything else gets environment-aware defaults.
module "service" {
  source = "../.."

  service     = "my-service"
  environment = "dev"
}

output "db_endpoint" {
  value = module.service.db_endpoint
}
