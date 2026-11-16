from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram

# Cached redirects are sub-millisecond, so the low buckets matter.
LATENCY_BUCKETS = (0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5)

HTTP_REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "route", "status"])
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
    buckets=LATENCY_BUCKETS,
)
REDIRECT_CACHE = Counter(
    "redirect_cache_total",
    "Redirect cache lookups",
    ["result"],  # hit | negative_hit | miss
)
CACHE_ITEMS = Gauge("redirect_cache_items", "Items in redirect cache")

CLICK_BUFFER_KEYS = Gauge("click_buffer_keys", "Link-hour buckets with unflushed clicks")
CLICKS_FLUSHED = Counter("clicks_flushed_total", "Clicks written to the database")
CLICK_FLUSH_DURATION = Histogram(
    "click_flush_duration_seconds", "Time to flush buffered clicks", buckets=LATENCY_BUCKETS
)
CLICK_FLUSH_ERRORS = Counter("click_flush_errors_total", "Failed click flushes")

DB_POOL_CHECKED_OUT = Gauge("db_pool_checked_out", "DB connections in use")
DB_POOL_SIZE = Gauge("db_pool_size", "Max DB connections for this process")
