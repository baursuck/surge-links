from __future__ import annotations

import asyncio
import logging
import re
import secrets
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from typing import NamedTuple

from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import RedirectResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from . import metrics
from .cache import TTLCache
from .clicks import ClickBuffer
from .config import Settings, settings
from .db_auth import enable_rds_iam_auth
from .logging_setup import setup_logging
from .middleware import MetricsMiddleware
from .models import Link, LinkClicksHourly
from .schemas import LinkCreate, LinkOut, LinkStats
from .shortcode import new_code

log = logging.getLogger(__name__)

CODE_RE = re.compile(r"^[A-Za-z0-9]{4,16}$")


class CachedLink(NamedTuple):
    id: int
    target_url: str
    expires_at: datetime | None


# Cached "this code does not exist" marker: a spike on a typo'd link must not hit the DB.
NOT_FOUND = CachedLink(-1, "", None)


def create_app(cfg: Settings = settings) -> FastAPI:
    setup_logging(cfg.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        engine = create_async_engine(
            cfg.database_url,
            pool_size=cfg.db_pool_size,
            max_overflow=cfg.db_max_overflow,
            pool_pre_ping=True,
        )
        if cfg.db_iam_auth:
            enable_rds_iam_auth(engine.sync_engine, cfg.aws_region)
        app.state.engine = engine
        app.state.db_seen_ok = False
        app.state.sessions = async_sessionmaker(engine, expire_on_commit=False)
        app.state.cache = TTLCache[CachedLink](cfg.cache_ttl_seconds, cfg.cache_max_items)
        app.state.inflight = {}  # code -> asyncio.Future, single-flight for cache misses
        app.state.clicks = ClickBuffer(engine, cfg.click_flush_interval_seconds)
        app.state.clicks.start()
        metrics.DB_POOL_SIZE.set(cfg.db_pool_size + cfg.db_max_overflow)
        metrics.DB_POOL_CHECKED_OUT.set_function(lambda: engine.pool.checkedout())
        metrics.CACHE_ITEMS.set_function(lambda: len(app.state.cache))
        log.info("startup complete")
        try:
            yield
        finally:
            await app.state.clicks.stop()
            await engine.dispose()
            log.info("shutdown complete, clicks flushed")

    app = FastAPI(title="surge-links", version="0.1.0", lifespan=lifespan)
    app.add_middleware(MetricsMiddleware)

    def short_url(code: str) -> str:
        return cfg.public_base_url.rstrip("/") + "/" + code

    def check_code(code: str) -> None:
        # Manual check instead of a Path pattern: /favicon.ico should be 404, not 422.
        if not CODE_RE.match(code):
            raise HTTPException(status_code=404, detail="link not found")

    async def lookup(request: Request, code: str) -> CachedLink:
        cache: TTLCache[CachedLink] = request.app.state.cache
        cached = cache.get(code)
        if cached is not None:
            metrics.REDIRECT_CACHE.labels("negative_hit" if cached is NOT_FOUND else "hit").inc()
            return cached

        metrics.REDIRECT_CACHE.labels("miss").inc()
        inflight: dict[str, asyncio.Future] = request.app.state.inflight
        if code in inflight:  # another request is already loading this code
            return await asyncio.shield(inflight[code])

        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        inflight[code] = fut
        try:
            try:
                async with request.app.state.sessions() as session:
                    row = (
                        await session.execute(
                            select(Link.id, Link.target_url, Link.expires_at).where(
                                Link.code == code
                            )
                        )
                    ).first()
            except (SQLAlchemyError, OSError) as exc:
                # Cached links keep working; only cold codes fail, and with a retryable status.
                raise HTTPException(status_code=503, detail="temporarily unavailable") from exc
            if row is None:
                link = NOT_FOUND
                cache.set(code, link, ttl=cfg.negative_cache_ttl_seconds)
            else:
                link = CachedLink(row.id, row.target_url, row.expires_at)
                cache.set(code, link)
            fut.set_result(link)
            return link
        except BaseException as exc:
            fut.set_exception(exc)
            fut.exception()  # mark retrieved so waiters-less failures don't warn
            raise
        finally:
            inflight.pop(code, None)

    @app.get("/healthz", include_in_schema=False)
    async def healthz() -> dict:
        return {"status": "ok"}

    @app.get("/readyz", include_in_schema=False)
    async def readyz(request: Request) -> dict:
        """Ready once the database has been reachable at least once.

        After that, a database outage does NOT make pods unready: every pod would leave the
        load balancer at the same moment and even cached redirects would stop. Instead the pod
        keeps serving from cache, cold codes get 503, and alerts fire on the error budget.
        """
        try:
            async with asyncio.timeout(cfg.db_ready_timeout_seconds):
                async with request.app.state.engine.connect() as conn:
                    await conn.execute(text("SELECT 1"))
            request.app.state.db_seen_ok = True
            return {"status": "ready", "db": "ok"}
        except Exception as exc:
            if request.app.state.db_seen_ok:
                return {"status": "ready", "db": "unavailable"}
            raise HTTPException(status_code=503, detail="database unavailable") from exc

    @app.get("/metrics", include_in_schema=False)
    async def prometheus_metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.post("/api/v1/links", response_model=LinkOut, status_code=201)
    async def create_link(
        body: LinkCreate,
        request: Request,
        x_api_key: str | None = Header(default=None),
    ) -> LinkOut:
        if cfg.api_key and not (x_api_key and secrets.compare_digest(x_api_key, cfg.api_key)):
            raise HTTPException(status_code=401, detail="invalid api key")
        expires_at = None
        if body.expires_in_seconds:
            expires_at = datetime.now(UTC) + timedelta(seconds=body.expires_in_seconds)
        async with request.app.state.sessions() as session:
            for _ in range(5):
                link = Link(
                    code=new_code(cfg.code_length),
                    target_url=str(body.target_url),
                    campaign=body.campaign,
                    expires_at=expires_at,
                )
                session.add(link)
                try:
                    await session.commit()
                    break
                except IntegrityError:
                    await session.rollback()
            else:
                raise HTTPException(status_code=503, detail="could not allocate a short code")
        request.app.state.cache.invalidate(link.code)  # drop a stale negative entry
        return LinkOut(
            code=link.code,
            short_url=short_url(link.code),
            target_url=link.target_url,
            campaign=link.campaign,
            expires_at=link.expires_at,
        )

    @app.get("/api/v1/links/{code}/stats", response_model=LinkStats)
    async def link_stats(code: str, request: Request) -> LinkStats:
        check_code(code)
        since = datetime.now(UTC) - timedelta(hours=24)
        async with request.app.state.sessions() as session:
            link = await session.scalar(select(Link).where(Link.code == code))
            if link is None:
                raise HTTPException(status_code=404, detail="link not found")
            last_24h = await session.scalar(
                select(func.coalesce(func.sum(LinkClicksHourly.clicks), 0)).where(
                    LinkClicksHourly.link_id == link.id, LinkClicksHourly.hour >= since
                )
            )
        return LinkStats(
            code=link.code,
            target_url=link.target_url,
            campaign=link.campaign,
            clicks_total=link.clicks,
            clicks_last_24h=int(last_24h or 0),
            created_at=link.created_at,
        )

    @app.get("/{code}", include_in_schema=False)
    async def follow(code: str, request: Request):
        check_code(code)
        link = await lookup(request, code)
        if link is NOT_FOUND:
            raise HTTPException(status_code=404, detail="link not found")
        if link.expires_at is not None and link.expires_at <= datetime.now(UTC):
            raise HTTPException(status_code=410, detail="link expired")
        request.app.state.clicks.add(link.id)
        return RedirectResponse(link.target_url, status_code=307)

    return app


app = create_app()
