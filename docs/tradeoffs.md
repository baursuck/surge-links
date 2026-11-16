# Trade-offs

| Decision | Why | Cost |
|---|---|---|
| Clicks buffered in memory, flushed every 1 s | one UPDATE per link per second instead of per click; no hot-row lock contention | a hard crash (SIGKILL/OOM) loses up to 1 s of clicks per pod; graceful shutdown flushes |
| Per-pod cache, no Redis | fewer moving parts; hot campaign links are few | each pod warms its own cache; links are changed rarely, 30 s TTL is acceptable |
| Hourly pre-aggregated clicks table | stats queries read 24 rows, not millions of events | no per-click detail (country, device) |
| One uvicorn worker per pod | metrics, cache and buffer are per-process and stay correct | scale with replicas, not workers |
| No CPU limit, only request | CPU throttling hurts p99 during spikes | a runaway pod can use spare node CPU |
| No VPC flow logs | cost for a demo | would be enabled in a real account (ignored in trivy with a comment) |
| `PowerUserAccess` for the CI deploy role | keeps the demo short | real setup: scoped policy + permissions boundary |
