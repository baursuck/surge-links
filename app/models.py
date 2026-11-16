from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, Index, String, Text, func, text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Link(Base):
    __tablename__ = "links"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    code: Mapped[str] = mapped_column(String(16), unique=True, nullable=False)
    target_url: Mapped[str] = mapped_column(Text, nullable=False)
    campaign: Mapped[str | None] = mapped_column(String(64))
    clicks: Mapped[int] = mapped_column(BigInteger, nullable=False, server_default=text("0"))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        Index(
            "ix_links_campaign",
            "campaign",
            postgresql_where=text("campaign IS NOT NULL"),
        ),
    )


class LinkClicksHourly(Base):
    """Pre-aggregated click counters: one row per link per hour instead of one row per click."""

    __tablename__ = "link_clicks_hourly"

    link_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("links.id", ondelete="CASCADE"), primary_key=True
    )
    hour: Mapped[datetime] = mapped_column(DateTime(timezone=True), primary_key=True)
    clicks: Mapped[int] = mapped_column(BigInteger, nullable=False)
