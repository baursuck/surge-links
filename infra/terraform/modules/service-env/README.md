# service-env

A blueprint for launching one service in its own AWS account: VPC, private Postgres and an
IAM role for the pods. A product team writes ~10 lines and gets environment-aware defaults.

```hcl
module "service" {
  source      = "../../modules/service-env"
  service     = "surge-links"
  environment = "prod"
}
```

## What you get

| Resource | dev / staging default | prod default |
|---|---|---|
| VPC, 2 AZ, public + private subnets | yes | yes |
| NAT gateway | 1 shared | 1 per AZ |
| RDS Postgres 17, gp3, encrypted, private | single-AZ | Multi-AZ |
| Backups / PITR window | 3 days | 14 days |
| Deletion protection, final snapshot | off | on |
| Master password | Secrets Manager, rotated by RDS | same |
| IAM role for the K8s service account (IRSA) | when `eks_oidc_provider_arn` is set | same |

Every default can be overridden, but the safe choice is the one you get without thinking.

## Design decisions

- **No secrets in state.** `manage_master_user_password` keeps the DB password in Secrets Manager;
  the pod role can read only that one secret.
- **DB reachable only from the app security group**, never from the VPC CIDR.
- **`max_connections` is an input**, because it has to be sized against
  `HPA max replicas x per-pod pool` (see [docs/capacity.md](../../../../docs/capacity.md)).
- **Plain resources, no community modules**, so every line can be reviewed and explained.
- **Validation on inputs** (names, environment, CIDR size) fails `plan` early with a clear message.

## Cost drivers (eu-central-1, rough on-demand list prices)

| Item | Why it costs | dev | prod |
|---|---|---|---|
| NAT gateway | hourly + per-GB processed | ~$35/mo | ~$70/mo (x2) |
| RDS db.t4g.micro | instance hours | ~$15/mo | ~$30/mo (Multi-AZ) |
| Storage gp3 20 GB + backups | per GB | ~$3/mo | ~$6/mo |

Check the current AWS pricing pages before relying on these numbers.
NAT is usually the surprise; VPC endpoints for S3/ECR cut its data charges.

## Tests

`terraform test` runs plan-only checks against a mocked AWS provider (no credentials, no cost):
dev is cheap, prod is safe, the DB is private and encrypted, subnets don't overlap,
the IRSA role is created only when a cluster is given, bad inputs are rejected.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Each one has a description.
