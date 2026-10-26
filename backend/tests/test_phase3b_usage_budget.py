"""Fase 3B: custos informados, deduplicação, isolamento, orçamento e streaming."""
import asyncio
import sqlite3

import pytest

from app.core import usage_ledger as ledger
from app.core.account_privacy import delete_account_data
from app.llm import LLMClient, LLMError


@pytest.fixture(autouse=True)
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.delenv("GAMA_USER_DAILY_COST_LIMIT_USD", raising=False)
    monkeypatch.delenv("GAMA_GLOBAL_DAILY_COST_LIMIT_USD", raising=False)
    monkeypatch.delenv("GAMA_LLM_BUDGET_RESERVATION_USD", raising=False)
    token = ledger.bind_owner(None)
    yield
    ledger.restore_owner(token)


def test_provider_reported_cost_and_unknown_not_zero():
    assert ledger.record_usage("alice", provider="openrouter", category="llm", model="a/x",
                               generation_id="gen-123", usage={"prompt_tokens": 100,
                                "completion_tokens": 20, "cost": 0.000375,
                                "prompt_tokens_details": {"cached_tokens": 80},
                                "completion_tokens_details": {"reasoning_tokens": 4}})
    assert not ledger.record_usage("alice", provider="openrouter", category="llm", model="a/x",
                                   generation_id="gen-123", usage={"cost": 999})
    ledger.record_usage("bob", provider="openrouter", category="image", model="image/x", usage={})
    data = ledger.overview()
    assert data["llm_and_media_calls"] == 2
    assert data["unknown_cost_calls"] == 1
    assert data["reported_cost_usd"] == 0.000375
    llm = next(m for m in data["models"] if m["category"] == "llm")
    assert llm["cached_tokens"] == 80
    assert llm["reasoning_tokens"] == 4
    assert "alice" not in str(data) and "bob" not in str(data)


def test_budgets_reserve_atomically_and_release(monkeypatch):
    monkeypatch.setenv("GAMA_USER_DAILY_COST_LIMIT_USD", "1.00")
    monkeypatch.setenv("GAMA_LLM_BUDGET_RESERVATION_USD", "0.6")
    hold = ledger.reserve_budget("alice")
    assert hold
    with pytest.raises(ledger.BudgetExceeded):
        ledger.reserve_budget("alice")
    # Reservations are per-owner for individual limits.
    assert ledger.reserve_budget("bob")
    ledger.release_budget(hold)
    ledger.record_usage("alice", provider="openrouter", category="llm", model="m", usage={"cost": 0.7})
    with pytest.raises(ledger.BudgetExceeded):
        ledger.reserve_budget("alice")


def test_global_budget_prevents_parallel_reservations(monkeypatch):
    monkeypatch.setenv("GAMA_GLOBAL_DAILY_COST_LIMIT_USD", "0.8")
    monkeypatch.setenv("GAMA_LLM_BUDGET_RESERVATION_USD", "0.5")
    assert ledger.reserve_budget("alice")
    with pytest.raises(ledger.BudgetExceeded):
        ledger.reserve_budget("bob")


def test_deleting_account_removes_ledger_without_affecting_other_user():
    for uid in ("alice", "bob"):
        ledger.record_usage(uid, provider="openrouter", category="llm", model="m", usage={"cost": 0.4})
    result = delete_account_data("alice")
    assert result["status"] == "deleted"
    assert ledger.overview()["reported_cost_usd"] == 0.4
    assert not ledger.record_usage("alice", provider="openrouter", category="llm", model="m", usage={"cost": 3})
    with sqlite3.connect(ledger._db_path()) as db:
        assert db.execute("SELECT COUNT(*) FROM usage_events WHERE owner='bob'").fetchone()[0] == 1
        assert db.execute("SELECT COUNT(*) FROM usage_events WHERE owner='alice'").fetchone()[0] == 0


@pytest.mark.asyncio
async def test_stream_ledger_recorded_only_once(monkeypatch):
    from app import llm as llm_module
    monkeypatch.setattr(llm_module.settings, "PROVIDER", "openrouter")
    client = LLMClient()
    async def mock_inner(*args, **kwargs):
        yield {"type": "token", "text": "olá"}
        yield {"type": "usage", "usage": {"prompt_tokens": 12, "completion_tokens": 3, "cost": 0.004}, "generation_id": "gen-one"}
        yield {"type": "finish", "reason": "stop"}
    monkeypatch.setattr(client, "_stream_events_inner", mock_inner)
    token = ledger.bind_owner("alice")
    try:
        result = [v async for v in client.stream_events("fake/model", [])]
    finally:
        ledger.restore_owner(token)
    assert [x["type"] for x in result] == ["token", "usage", "finish"]
    assert ledger.overview()["reported_cost_usd"] == 0.004
    assert ledger.overview()["llm_and_media_calls"] == 1


@pytest.mark.asyncio
async def test_nonstream_ledger_usage(monkeypatch):
    from app import llm as llm_module
    monkeypatch.setattr(llm_module.settings, "PROVIDER", "openrouter")
    client = LLMClient()
    async def mock_inner(*args, **kwargs):
        return {"text": "ok", "usage": {"prompt_tokens": 2, "completion_tokens": 1, "cost": 0.001}, "generation_id": "gen-two"}
    monkeypatch.setattr(client, "_chat_once_meta_inner", mock_inner)
    token = ledger.bind_owner("alice")
    try:
        assert (await client.chat_once_meta("fake/model", []))["text"] == "ok"
    finally:
        ledger.restore_owner(token)
    assert ledger.overview()["reported_cost_usd"] == 0.001

@pytest.mark.asyncio
async def test_account_usage_endpoint_is_scoped_to_verified_user(monkeypatch):
    import httpx
    from app.core import identity
    from app.main import app

    async def verifier(token):
        if token == "account-a":
            return "google_email_alice@example.com"
        if token == "account-b":
            return "google_email_bob@example.com"
        raise PermissionError("token inválido")

    monkeypatch.setenv("GAMA_REQUIRE_AUTH", "1")
    monkeypatch.setattr(identity, "_verifier", verifier)
    identity._token_cache.clear()
    for who, cost in (("google_email_alice@example.com", 0.20),
                      ("google_email_bob@example.com", 0.70)):
        ledger.record_usage(who, provider="openrouter", category="llm", model="m", usage={"cost": cost})
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        assert (await client.get("/account/usage")).status_code == 401
        alice = await client.get("/account/usage", headers={"Authorization": "Bearer account-a"})
        bob = await client.get("/account/usage", headers={"Authorization": "Bearer account-b"})
    identity._token_cache.clear()
    assert alice.status_code == 200, alice.text
    assert bob.status_code == 200, bob.text
    assert alice.json()["reported_cost_usd"] == 0.2
    assert bob.json()["reported_cost_usd"] == 0.7
    assert "@example.com" not in str(alice.json())
