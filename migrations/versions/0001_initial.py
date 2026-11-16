"""initial schema

Revision ID: 0001
Revises:
Create Date: 2026-11-16
"""

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "links",
        sa.Column("id", sa.BigInteger(), sa.Identity(), primary_key=True),
        sa.Column("code", sa.String(16), nullable=False),
        sa.Column("target_url", sa.Text(), nullable=False),
        sa.Column("campaign", sa.String(64), nullable=True),
        sa.Column("clicks", sa.BigInteger(), nullable=False, server_default=sa.text("0")),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("code", name="uq_links_code"),
    )
    op.create_index(
        "ix_links_campaign",
        "links",
        ["campaign"],
        postgresql_where=sa.text("campaign IS NOT NULL"),
    )
    op.create_table(
        "link_clicks_hourly",
        sa.Column(
            "link_id",
            sa.BigInteger(),
            sa.ForeignKey("links.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("hour", sa.DateTime(timezone=True), nullable=False),
        sa.Column("clicks", sa.BigInteger(), nullable=False),
        sa.PrimaryKeyConstraint("link_id", "hour", name="pk_link_clicks_hourly"),
    )


def downgrade() -> None:
    op.drop_table("link_clicks_hourly")
    op.drop_index("ix_links_campaign", table_name="links")
    op.drop_table("links")
