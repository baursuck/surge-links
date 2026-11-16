# Launching a new service in 3 steps

The Terraform module `service-env` and the Helm chart are meant to be copied by product teams.

**1. Infrastructure.** Create `infra/terraform/envs/<env>/main.tf`:

```hcl
module "my_service" {
  source      = "../../modules/service-env"
  service     = "my-service"
  environment = "dev"
}
```

Open a PR. CI runs `fmt`, `validate`, `tflint`, a security scan and the module's tests.
Production gets Multi-AZ, deletion protection and 14 days of backups without anyone asking.

**2. Secret.** Map the RDS secret (`db_secret_arn` output) to a Kubernetes Secret named
`<service>-db` with key `DATABASE_URL` (External Secrets Operator in a real cluster).

**3. Deploy.**

```bash
helm upgrade --install my-service deploy/helm/surge-links \
  --set image.repository=ghcr.io/org/my-service \
  --set serviceAccount.roleArn=<app_role_arn output>
```

Migrations run as a pre-upgrade hook, the HPA is already tuned for spikes, and the service
exposes `/metrics` with the same metric names, so the SLO rules and the dashboard work unchanged.
