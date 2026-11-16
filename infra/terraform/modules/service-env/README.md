# service-env

A blueprint for launching one service into an AWS account (one account per environment,
prepared once by `bootstrap/aws-account`): VPC, private Postgres and an IAM role for the pods. A product team writes ~10 lines and gets environment-aware defaults.

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
| Master password | Secrets Manager, rotated by RDS, admins only | same |
| Pod login to Postgres | IAM auth token as `app_user`, no password | same |
| IAM role for the K8s service account (IRSA) | when `eks_oidc_provider_arn` is set | same |

Every default can be overridden, but the safe choice is the one you get without thinking.

## Design decisions

- **No passwords for the app.** Pods connect as `app_user` with a 15-minute IAM token
  (`rds-db:connect` on that one user). The master password lives in Secrets Manager, is rotated
  by RDS and is never in state or in the cluster, so rotation cannot break running pods.
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

## Not in this module

The EKS cluster itself, the ingress controller and External Secrets: they are shared platform
pieces, one per cluster, not per service. The module takes the cluster's OIDC provider ARN as
input. Pods join the `app` security group through a `SecurityGroupPolicy` in the Helm chart
(security groups for pods, VPC CNI).

## Tests

`terraform test` runs plan-only checks against a mocked AWS provider (no credentials, no cost):
dev is cheap, prod is safe, the DB is private and encrypted, subnets don't overlap,
the IRSA role is created only when a cluster is given, bad inputs are rejected.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Each one has a description.
