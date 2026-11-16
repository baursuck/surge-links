# Runbook

Each alert links here. First question every time: **is a campaign running right now?**
(Grafana: "Redirects / s"). A spike explains most symptoms.

## RedirectErrorBudgetFastBurn
5xx on redirects.
1. Grafana → "Requests by route and status": which status code? Loki panel: which error?
2. `kubectl get pods`: are pods restarting (OOM, failed liveness)?
3. `/readyz` shows `"db": "unavailable"` → database. Pods stay in rotation on purpose and keep
   serving cached links; cold codes return 503. Check RDS CPU, connections, Performance Insights.
4. Started right after a deploy → `helm rollback surge-links`.

## RedirectErrorBudgetSlowBurn
Same checks without urgency; open a ticket with the graphs attached.

## RedirectLatencyBudgetFastBurn
1. Cache hit ratio dropped? A new campaign with many cold links → misses go to Postgres.
2. CPU throttling or pods at the HPA maximum → raise `maxReplicas` (check docs/capacity.md first).
3. Slow queries: Postgres logs everything over 250 ms (`log_min_duration_statement`).

## RedirectLatencyBudgetSlowBurn
Same checks as the fast burn, during work hours: cache hit ratio, slow query log, HPA at maximum.

## SurgeLinksTargetDown
1. `kubectl get pods`: CrashLoopBackOff? `kubectl logs --previous` shows why.
2. All pods fine but no scrape → ServiceMonitor or network policy changed.
3. Nothing at all → check the last deploy (`helm history surge-links`) and roll back.

## ClickFlushFailing
Clicks are piling up in pod memory. Redirects still work, but a pod restart loses buffered clicks.
1. Loki: `{container=~".*app.*"} |= "click flush failed"` shows the exception.
2. Usually DB connectivity or a lock → check RDS. Flushes retry every second automatically.
3. Do not restart pods while it fires, unless memory is growing toward the limit.

## DbPoolSaturated
1. Is it one pod or all of them? One pod → noisy neighbour or a stuck query.
2. All pods during a spike → see docs/capacity.md (RDS Proxy is the structural fix).

## Disaster recovery

Local drill: `make dr` (backup → drop database → restore → verify → prints RTO).

On AWS (RDS):
1. Point-in-time restore to a new instance: `aws rds restore-db-instance-to-point-in-time
   --source-db-instance-identifier surge-links-prod --target-db-instance-identifier
   surge-links-prod-restore --use-latest-restorable-time`.
2. Update the `DATABASE_URL` secret to the new endpoint and `kubectl rollout restart`.
3. Verify with the stats endpoint for a known link, then rename or retire the old instance.

RPO on RDS is about 5 minutes (transaction log upload interval); plus at most one second of
buffered clicks per pod.
