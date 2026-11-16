# Capacity and the connection budget

Every pod holds its own SQLAlchemy pool. Under a spike the HPA adds pods, and each new pod opens
connections, so **autoscaling can take the database down** if nobody does this arithmetic.

```
connections needed = maxReplicas x (DB_POOL_SIZE + DB_MAX_OVERFLOW) + migrations + admin
prod:              = 20 x (5 + 5) + 1 + ~10 = ~211
RDS max_connections (prod, set in Terraform) = 300   -> ~30% headroom
```

`db.t4g.medium` (4 GiB) is chosen for prod because each Postgres connection costs memory;
300 connections on a 2 GiB instance would leave little for shared buffers. Dev runs on
`db.t4g.micro` (1 GiB) with `max_connections = 100`, so dev must keep `maxReplicas` at 5 or less
(5 x 10 + headroom).

## Why the pool is small (5 + 5)

The hot path barely touches Postgres:

- **Redirects** are served from an in-process cache (30 s TTL, plus a 5 s negative cache for
  unknown codes). Concurrent misses for the same code are collapsed into one query (single-flight).
- **Clicks** are counted in memory and written once per second per pod as one batched
  `UPDATE ... FROM unnest(...)`, so 2 000 clicks/s become about 20 statements/s
  (one per pod), not 2 000.

## When to change the design

| Symptom | Next step |
|---|---|
| `DbPoolSaturated` fires during spikes | add RDS Proxy or PgBouncer in front of Postgres, keep pools per pod small |
| need more than ~30 pods | same: connection multiplexing becomes mandatory |
| clicks lag behind or flush takes > 100 ms | partition `link_clicks_hourly` by month, or move clicks to a queue |
| cache hit ratio drops (many distinct links) | shared cache (Redis/ElastiCache) instead of per-pod |

## Scaling behaviour

HPA (`deploy/helm/surge-links/templates/hpa.yaml`): CPU target 60%, scale-up with no
stabilization window (double pods every 15 s), scale-down only after 5 minutes because
campaigns come in waves. `minReplicas: 3` keeps one pod per AZ and absorbs the first seconds
of a spike before new pods are ready.
