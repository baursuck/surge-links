# SLOs

Only the redirect path (`GET /{code}`) has SLOs: that is what ad networks and users hit, and
what breaks a campaign. The admin API (create link, stats) is best effort.

| SLI | Good event | SLO (30 days) | Error budget |
|---|---|---|---|
| Availability | redirect answered without 5xx (404/410 are correct answers) | 99.9% | 0.1% ≈ 43 min of full outage |
| Latency | redirect served in < 100 ms (server side) | 99% | 1% of redirects may be slower |

Health probes and `/metrics` scrapes are excluded from the SLIs (see `app/middleware.py`).

## Alerting

Multi-window, multi-burn-rate alerts (Google SRE workbook, ch. 5), rules in
[`observability/prometheus/slo-rules.yml`](../observability/prometheus/slo-rules.yml):

| Alert | Condition | Meaning | Action |
|---|---|---|---|
| `RedirectErrorBudgetFastBurn` | 1h and 5m error ratio > 14.4 x 0.1% | 2% of the monthly budget gone in an hour | page |
| `RedirectErrorBudgetSlowBurn` | 6h and 30m error ratio > 6 x 0.1% | 5% of the budget in 6 hours | ticket |
| `RedirectLatencyBudgetFastBurn` | 1h and 5m slow ratio > 14.4 x 1% | latency SLO burning fast | page |
| `RedirectLatencyBudgetSlowBurn` | 6h and 30m slow ratio > 6 x 1% | latency budget burning steadily | ticket |
| `SurgeLinksTargetDown` / `SurgeLinksAbsent` | `up == 0` or no targets at all | nothing answers, burn-rate ratios are NaN and silent | page |
| `ClickFlushFailing` | flush errors while clicks are buffered | stats are not being saved | page |
| `DbPoolSaturated` | a pod uses > 90% of its pool for 5 min | close to connection exhaustion | ticket |

The short window stops the alert quickly once the problem is fixed; the long one avoids paging
on a short blip.

Where 14.4 and 6 come from: budget for 30 days = 0.1%. Burning 2% of it in 1 hour means
`0.02 x 720 h / 1 h = 14.4` times the allowed rate; 5% in 6 hours means `0.05 x 720 / 6 = 6`.

At zero traffic the ratios divide 0 by 0 and every burn-rate alert goes quiet; that is why
`SurgeLinksTargetDown` / `SurgeLinksAbsent` exist. In production the alerts go to Alertmanager
(page → on-call, ticket → team channel); the local stack evaluates rules but has no Alertmanager.

## Why these numbers

- 99.9% and not 99.99%: one region, one database. 99.99% would need multi-region and is not
  worth it for a link redirect.
- 100 ms: the redirect sits in front of a landing page. A cached redirect is about a
  millisecond; the 100 ms threshold leaves room for cache misses and GC pauses.
