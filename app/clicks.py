from __future__ import annotations

import asyncio
import logging
import random
import time
from collections import defaultdict
from datetime import UTC, datetime

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from . import metrics

log = logging.getLogger(__name__)

# Hot links get one UPDATE per flush instead of one per click, which removes row-lock
# contention when a campaign link receives thousands of hits per second.
# Many pods flush the same hot links: rows are locked in id order (FOR UPDATE ... ORDER BY)
# so two concurrent flushes can wait for each other but never deadlock.
# Explicit array casts: asyncpg cannot infer the element type of an untyped unnest().
_UPDATE_TOTALS = text(
    """
    WITH v AS (
        SELECT id, sum(n) AS n
          FROM unnest(CAST(:ids AS bigint[]), CAST(:ns AS bigint[])) AS u(id, n)
         GROUP BY id
    ), locked AS (
        SELECT l.id FROM links l JOIN v ON v.id = l.id ORDER BY l.id FOR UPDATE OF l
    )
    UPDATE links AS l
       SET clicks = l.clicks + v.n
      FROM v
     WHERE l.id = v.id
       AND l.id IN (SELECT id FROM locked)
    """
)

# The hour is taken from when the click happened (bucketed at add time), not from
# flush time, so batches retried after an outage still land in the right hour.
_UPSERT_HOURLY = text(
    """
    INSERT INTO link_clicks_hourly (link_id, hour, clicks)
    SELECT v.id, v.hour, v.n
      FROM unnest(
             CAST(:ids AS bigint[]),
             CAST(:hours AS timestamptz[]),
             CAST(:ns AS bigint[])
           ) AS v(id, hour, n)
      JOIN links l ON l.id = v.id
     ORDER BY v.id, v.hour  -- same lock order on every pod
    ON CONFLICT (link_id, hour)
    DO UPDATE SET clicks = link_clicks_hourly.clicks + EXCLUDED.clicks
    """
)


def _hour_now() -> datetime:
    return datetime.now(UTC).replace(minute=0, second=0, microsecond=0)


class ClickBuffer:
    """Counts clicks in memory and writes them to Postgres in batches.

    Trade-off: stats lag by up to one flush interval, and a hard crash (SIGKILL, OOM)
    loses at most one interval of clicks. Graceful shutdown flushes everything.
    """

    def __init__(self, engine: AsyncEngine, interval: float) -> None:
        self._engine = engine
        self._interval = interval
        self._counts: defaultdict[tuple[int, datetime], int] = defaultdict(int)
        self._lock = asyncio.Lock()
        self._stopping = asyncio.Event()
        self._task: asyncio.Task | None = None

    def add(self, link_id: int) -> None:
        self._counts[(link_id, _hour_now())] += 1
        metrics.CLICK_BUFFER_KEYS.set(len(self._counts))

    def _requeue(self, batch: dict[tuple[int, datetime], int]) -> None:
        for key, n in batch.items():
            self._counts[key] += n
        metrics.CLICK_BUFFER_KEYS.set(len(self._counts))

    async def flush(self) -> int:
        async with self._lock:
            if not self._counts:
                return 0
            batch, self._counts = self._counts, defaultdict(int)
            keys = sorted(batch.keys())
            params = {
                "ids": [k[0] for k in keys],
                "hours": [k[1] for k in keys],
                "ns": [batch[k] for k in keys],
            }
            started = time.perf_counter()
            try:
                async with self._engine.begin() as conn:
                    await conn.execute(_UPDATE_TOTALS, {"ids": params["ids"], "ns": params["ns"]})
                    await conn.execute(_UPSERT_HOURLY, params)
            except BaseException:
                # BaseException on purpose: a cancelled flush must not drop the batch.
                metrics.CLICK_FLUSH_ERRORS.inc()
                log.exception("click flush failed, requeued %d buckets", len(keys))
                self._requeue(batch)
                raise
            finally:
                metrics.CLICK_FLUSH_DURATION.observe(time.perf_counter() - started)
            metrics.CLICK_BUFFER_KEYS.set(len(self._counts))
            total = sum(params["ns"])
            metrics.CLICKS_FLUSHED.inc(total)
            return total

    async def _run(self) -> None:
        while not self._stopping.is_set():
            try:
                # +-20% jitter so pods do not all flush in the same millisecond.
                timeout = self._interval * random.uniform(0.8, 1.2)
                await asyncio.wait_for(self._stopping.wait(), timeout=timeout)
            except TimeoutError:
                pass
            try:
                await self.flush()
            except Exception:
                pass  # already logged and requeued; retry on the next tick

    def start(self) -> None:
        self._task = asyncio.create_task(self._run(), name="click-flusher")

    async def stop(self) -> None:
        """Let the flusher finish its current flush, then flush whatever is left."""
        self._stopping.set()
        if self._task:
            await self._task
        await self.flush()
