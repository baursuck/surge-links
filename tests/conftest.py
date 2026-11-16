from __future__ import annotations

import os

import pytest
import pytest_asyncio
from alembic import command
from alembic.config import Config
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text

os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://surge:surge@localhost:5432/surge")

from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def migrated_db() -> None:
    command.upgrade(Config("alembic.ini"), "head")


@pytest_asyncio.fixture
async def app():
    # Long flush interval: tests flush explicitly, so results are deterministic.
    application = create_app(Settings(click_flush_interval_seconds=3600))
    async with LifespanManager(application):
        async with application.state.engine.begin() as conn:
            await conn.execute(text("TRUNCATE links RESTART IDENTITY CASCADE"))
        yield application


@pytest_asyncio.fixture
async def client(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
