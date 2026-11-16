from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://surge:surge@localhost:5432/surge"
    # Connection budget: replicas_max * (pool_size + max_overflow) must stay below
    # RDS max_connections minus headroom. See docs/capacity.md.
    db_pool_size: int = 5
    db_max_overflow: int = 5
    db_ready_timeout_seconds: float = 1.0
    # On AWS: log in as the IAM-authenticated DB user (DATABASE_URL has no password).
    db_iam_auth: bool = False
    aws_region: str = "eu-central-1"

    # Short links are built from this, not from the Host header (wrong behind ALB/ingress).
    public_base_url: str = "http://localhost:8000"
    # If set, POST /api/v1/links requires the X-API-Key header (prevents an open redirector).
    api_key: str | None = None

    code_length: int = 7
    cache_ttl_seconds: float = 30.0
    negative_cache_ttl_seconds: float = 5.0
    cache_max_items: int = 50_000
    click_flush_interval_seconds: float = 1.0

    log_level: str = "INFO"


settings = Settings()


def sync_database_url(url: str) -> str:
    """Alembic runs synchronously: swap the async driver for psycopg."""
    return url.replace("+asyncpg", "+psycopg")
