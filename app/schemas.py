from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field, HttpUrl


class LinkCreate(BaseModel):
    target_url: HttpUrl
    campaign: str | None = Field(default=None, max_length=64, pattern=r"^[a-z0-9_\-]+$")
    expires_in_seconds: int | None = Field(default=None, ge=60, le=60 * 60 * 24 * 365)


class LinkOut(BaseModel):
    code: str
    short_url: str
    target_url: str
    campaign: str | None
    expires_at: datetime | None


class LinkStats(BaseModel):
    code: str
    target_url: str
    campaign: str | None
    clicks_total: int
    clicks_last_24h: int
    created_at: datetime
