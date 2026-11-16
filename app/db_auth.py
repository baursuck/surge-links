"""RDS IAM authentication: the pod's IAM role signs a 15-minute token that is used as the
password for each new connection. No password is stored anywhere, so RDS rotating the master
secret can never break the app."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from sqlalchemy import event
from sqlalchemy.engine import Engine


def enable_rds_iam_auth(sync_engine: Engine, region: str) -> Callable[..., None]:
    import boto3  # imported lazily: local and CI runs use plain passwords

    rds = boto3.client("rds", region_name=region)
    driver = sync_engine.dialect.driver  # "asyncpg" or "psycopg"

    @event.listens_for(sync_engine, "do_connect")
    def provide_token(dialect: Any, conn_rec: Any, cargs: Any, cparams: dict) -> None:
        cparams["password"] = rds.generate_db_auth_token(
            DBHostname=cparams["host"],
            Port=int(cparams.get("port") or 5432),
            DBUsername=cparams["user"],
            Region=region,
        )
        # IAM auth requires TLS.
        if driver == "asyncpg":
            cparams["ssl"] = "require"
        else:
            cparams["sslmode"] = "require"

    return provide_token
