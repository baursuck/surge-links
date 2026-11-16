from __future__ import annotations

import sys
import types

from sqlalchemy import create_engine

from app.db_auth import enable_rds_iam_auth


def test_iam_token_is_used_as_password(monkeypatch):
    calls = {}

    class FakeRds:
        def generate_db_auth_token(self, **kw):
            calls.update(kw)
            return "signed-token"

    fake_boto3 = types.SimpleNamespace(client=lambda service, region_name: FakeRds())
    monkeypatch.setitem(sys.modules, "boto3", fake_boto3)

    engine = create_engine("postgresql+psycopg://app_user@db.example:5432/surge")
    hook = enable_rds_iam_auth(engine, "eu-central-1")

    cparams = {"host": "db.example", "port": 5432, "user": "app_user", "dbname": "surge"}
    hook(None, None, (), cparams)

    assert cparams["password"] == "signed-token"
    assert cparams["sslmode"] == "require"
    assert calls == {
        "DBHostname": "db.example",
        "Port": 5432,
        "DBUsername": "app_user",
        "Region": "eu-central-1",
    }
