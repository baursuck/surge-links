# Trade-offs

| Decision | Why | Cost |
|---|---|---|
| Clicks buffered in memory, flushed every 1 s | one UPDATE per link per second instead of per click; no hot-row lock contention | a hard crash (SIGKILL/OOM) loses up to 1 s of clicks per pod; graceful shutdown flushes |
| Rows locked in id order during flush, ±20% flush jitter | 20 pods updating the same hot links cannot deadlock and do not all hit Postgres in the same millisecond | flushes of the same link still queue behind each other; at ~50k rps clicks should go through a queue (Kinesis/Kafka) and be aggregated once |
| Readiness checks the DB only until the first success | a DB outage would otherwise pull every pod out of the load balancer at once and stop even cached redirects | a pod with a broken DB connection stays in rotation; cold codes get 503 and the burn-rate alerts fire |
| Pods log in to Postgres with IAM tokens | no app password to store or rotate; RDS rotating the master secret cannot break pods | token generation per new connection (local signing, cheap); `app_user` has to be created once by hand |
| Per-pod cache, no Redis | fewer moving parts; hot campaign links are few | each pod warms its own cache; links are changed rarely, 30 s TTL is acceptable |
| Hourly pre-aggregated clicks table | stats queries read 24 rows, not millions of events | no per-click detail (country, device) |
| One uvicorn worker per pod | metrics, cache and buffer are per-process and stay correct | scale with replicas, not workers |
| No CPU limit, only request | CPU throttling hurts p99 during spikes | a runaway pod can use spare node CPU |
| No VPC flow logs | cost for a demo | would be enabled in a real account (ignored in trivy with a comment) |
| Deployer role: wildcard EC2/RDS actions, IAM limited to `surge-links-*` roles | resource ARNs do not exist before the first apply | real setup: add a permissions boundary that every created role must carry |
