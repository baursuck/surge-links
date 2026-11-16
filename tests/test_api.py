from __future__ import annotations

from sqlalchemy import text


async def create(client, **body):
    body.setdefault("target_url", "https://example.com/landing")
    resp = await client.post("/api/v1/links", json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()


async def test_health(client):
    assert (await client.get("/healthz")).status_code == 200
    assert (await client.get("/readyz")).json() == {"status": "ready"}


async def test_create_and_redirect(client):
    link = await create(client, campaign="black_friday")
    assert len(link["code"]) == 7
    assert link["short_url"].endswith(link["code"])

    resp = await client.get(f"/{link['code']}")
    assert resp.status_code == 307
    assert resp.headers["location"] == "https://example.com/landing"


async def test_rejects_invalid_input(client):
    assert (await client.post("/api/v1/links", json={"target_url": "not-a-url"})).status_code == 422
    bad_campaign = {"target_url": "https://example.com", "campaign": "Bad Name!"}
    assert (await client.post("/api/v1/links", json=bad_campaign)).status_code == 422


async def test_unknown_code_is_404(client):
    assert (await client.get("/Zz9Zz9Z")).status_code == 404


async def test_expired_link_is_410(app, client):
    link = await create(client, expires_in_seconds=60)
    async with app.state.engine.begin() as conn:
        await conn.execute(
            text("UPDATE links SET expires_at = now() - interval '1 second' WHERE code = :c"),
            {"c": link["code"]},
        )
    assert (await client.get(f"/{link['code']}")).status_code == 410


async def test_clicks_are_batched_and_counted(app, client):
    link = await create(client, campaign="spring")
    for _ in range(5):
        await client.get(f"/{link['code']}")

    before = (await client.get(f"/api/v1/links/{link['code']}/stats")).json()
    assert before["clicks_total"] == 0  # still in the in-memory buffer

    flushed = await app.state.clicks.flush()
    assert flushed == 5

    stats = (await client.get(f"/api/v1/links/{link['code']}/stats")).json()
    assert stats["clicks_total"] == 5
    assert stats["clicks_last_24h"] == 5


async def test_clicks_from_concurrent_requests(app, client):
    import asyncio

    link = await create(client)
    await asyncio.gather(*(client.get(f"/{link['code']}") for _ in range(50)))
    assert await app.state.clicks.flush() == 50
    stats = (await client.get(f"/api/v1/links/{link['code']}/stats")).json()
    assert stats["clicks_total"] == 50


async def test_shutdown_flushes_buffer(app, client):
    link = await create(client)
    await client.get(f"/{link['code']}")
    await app.state.clicks.stop()  # what the lifespan does on SIGTERM
    async with app.state.engine.connect() as conn:
        total = (
            await conn.execute(
                text("SELECT clicks FROM links WHERE code = :c"), {"c": link["code"]}
            )
        ).scalar_one()
    assert total == 1


async def test_non_code_paths_are_404(client):
    assert (await client.get("/favicon.ico")).status_code == 404
    assert (await client.get("/api/v1/links/bad!code/stats")).status_code == 404


async def test_unknown_code_is_negatively_cached(client):
    await client.get("/Nope123")
    await client.get("/Nope123")
    body = (await client.get("/metrics")).text
    assert 'redirect_cache_total{result="negative_hit"}' in body


async def test_short_url_uses_public_base_url(client):
    link = await create(client)
    assert link["short_url"] == f"http://localhost:8000/{link['code']}"


async def test_redirect_cache_hits(client):
    link = await create(client)
    await client.get(f"/{link['code']}")
    await client.get(f"/{link['code']}")
    body = (await client.get("/metrics")).text
    assert 'redirect_cache_total{result="hit"}' in body
    assert "http_requests_total" in body
