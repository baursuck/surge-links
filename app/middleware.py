from __future__ import annotations

import time

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import metrics

# Probes and scrapes are not user traffic: keep them out of the SLIs.
_SKIP = {"/metrics", "/healthz", "/readyz"}


class MetricsMiddleware:
    """Pure ASGI middleware (cheaper than BaseHTTPMiddleware on the hot path)."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in _SKIP:
            await self.app(scope, receive, send)
            return

        started = time.perf_counter()
        status = 500

        async def send_wrapper(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            route = scope.get("route")
            path = getattr(route, "path", "unmatched")
            method = scope["method"]
            metrics.HTTP_REQUESTS.labels(method, path, str(status)).inc()
            metrics.HTTP_LATENCY.labels(method, path).observe(time.perf_counter() - started)
