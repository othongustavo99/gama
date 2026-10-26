"""Fase 3C: planos e créditos manuais; nenhum pagamento é feito."""
import asyncio
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest

from app.core import commercial_plans as plans
from app.core.account_privacy import delete_account_data


@pytest.fixture(autouse=True)
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("GAMA_REQUIRE_AUTH", "1")
    monkeypatch.delenv("GAMA_ADMIN_GOOGLE_EMAILS", raising=False)


ALICE = "google_email_alice@example.com"
BOB = "google_email_bob@example.com"
ADMIN = "google_email_admin@example.com"


def test_default_is_preview_only_and_free_without_grants():
    snapshot = plans.account_snapshot(ALICE)
    assert snapshot["plan"] == "free"
    assert snapshot["credits_balance"] == 0
    assert snapshot["enforcement_active"] is False
    assert snapshot["payments_active"] is False
    assert snapshot["limits_preview_only"] is True


def test_assign_plan_expires_and_is_idempotent():
    first = plans.assign_plan(ALICE, "pro", "assign-plan-001", duration_days=30)
    same = plans.assign_plan(ALICE, "pro", "assign-plan-001", duration_days=30)
    assert same["idempotent_replay"] is True
    assert first["expires_at"] == same["expires_at"]
    assert plans.account_snapshot(ALICE)["plan"] == "pro"
    assert plans.account_snapshot(BOB)["plan"] == "free"
    with pytest.raises(plans.CommercialError):
        plans.assign_plan(BOB, "pro", "assign-plan-001", duration_days=30)
    with pytest.raises(plans.CommercialError):
        plans.assign_plan(ALICE, "creator", "assign-plan-001", duration_days=30)
    with plans._connect() as db:
        db.execute("UPDATE plan_assignments SET expires_at='2000-01-01T00:00:00+00:00' WHERE owner=?", (ALICE,))
    assert plans.account_snapshot(ALICE)["plan"] == "free"


def test_credits_atomic_and_idempotent():
    a = plans.adjust_credits(ALICE, 100, "credit-grant-0001", reason="tester beta")
    b = plans.adjust_credits(ALICE, 100, "credit-grant-0001", reason="tester beta")
    assert a["credits_balance"] == b["credits_balance"] == 100
    assert b["idempotent_replay"] is True
    assert plans.adjust_credits(ALICE, -40, "credit-spend-0001", reason="ajuste beta")["credits_balance"] == 60
    with pytest.raises(plans.InsufficientCredits):
        plans.adjust_credits(ALICE, -70, "credit-spend-0002", reason="ajuste beta")
    assert plans.account_snapshot(BOB)["credits_balance"] == 0
    with pytest.raises(plans.CommercialError):
        plans.adjust_credits(BOB, 100, "credit-grant-0001", reason="tester beta")
    with pytest.raises(plans.CommercialError):
        plans.adjust_credits(ALICE, 100, "credit-grant-0001", reason="motivo diferente")


def test_credit_concurrency_does_not_go_negative():
    plans.adjust_credits(ALICE, 10, "credit-seed-00001", reason="crédito inicial")

    def charge(i):
        try:
            plans.adjust_credits(ALICE, -1, f"credit-charge-{i:03d}", reason="ajuste beta")
            return True
        except plans.InsufficientCredits:
            return False

    with ThreadPoolExecutor(max_workers=8) as pool:
        values = list(pool.map(charge, range(25)))
    assert sum(values) == 10
    assert plans.account_snapshot(ALICE)["credits_balance"] == 0


def test_feature_engine_is_idempotent_and_is_not_wired_into_generations():
    assert plans.claim_feature(ALICE, "image", "feature-image-0001")["accepted"]
    assert plans.claim_feature(ALICE, "image", "feature-image-0001")["idempotent_replay"]
    plans.claim_feature(ALICE, "image", "feature-image-0002")
    with pytest.raises(plans.FeatureLimitReached):
        plans.claim_feature(ALICE, "image", "feature-image-0003")
    with pytest.raises(plans.FeatureLimitReached):
        plans.claim_feature(ALICE, "video", "feature-video-0001")
    assert plans.account_snapshot(ALICE)["usage_today"]["image"] == 2
    assert plans.account_snapshot(ALICE)["enforcement_active"] is False


def test_account_deletion_is_scoped_and_blocks_reuse():
    plans.assign_plan(ALICE, "creator", "plan-delete-alice", duration_days=30)
    plans.adjust_credits(ALICE, 17, "grant-delete-alice", reason="teste exclusão")
    plans.adjust_credits(BOB, 42, "grant-delete-bobxx", reason="teste exclusão")
    assert delete_account_data(ALICE)["status"] == "deleted"
    assert plans.account_snapshot(BOB)["credits_balance"] == 42
    with pytest.raises(plans.CommercialError):
        plans.account_snapshot(ALICE)
    with plans._connect() as db:
        assert db.execute("SELECT COUNT(*) FROM credit_events WHERE owner=?", (ALICE,)).fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM plan_events WHERE owner=?", (ALICE,)).fetchone()[0] == 0


@pytest.mark.asyncio
async def test_admin_endpoints_deny_non_admin_and_account_is_private(monkeypatch):
    from app.core import identity
    from app.main import app

    async def verify(token):
        if token == "valid-admin":
            return ADMIN
        if token == "valid-alice":
            return ALICE
        if token == "valid-bob":
            return BOB
        raise PermissionError("token inválido")

    monkeypatch.setattr(identity, "_verifier", verify)
    identity._token_cache.clear()
    monkeypatch.setenv("GAMA_ADMIN_GOOGLE_EMAILS", "admin@example.com")
    admin = {"Authorization": "Bearer valid-admin"}
    alice = {"Authorization": "Bearer valid-alice"}
    bob = {"Authorization": "Bearer valid-bob"}
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        assert (await client.get("/admin/commercial/catalog")).status_code == 401
        assert (await client.get("/admin/commercial/catalog", headers=alice)).status_code == 403
        assert (await client.post("/admin/commercial/adjust-credits", headers=alice,
                                  json={"owner": ALICE, "delta": 50, "request_id": "http-credit-001"})).status_code == 403
        response = await client.post("/admin/commercial/adjust-credits", headers=admin,
                                     json={"owner": ALICE, "delta": 50, "request_id": "http-credit-001"})
        assert response.status_code == 200, response.text
        response2 = await client.post("/admin/commercial/assign-plan", headers=admin,
                                      json={"owner": ALICE, "plan": "pro", "duration_days": 14,
                                            "request_id": "http-plan-001"})
        assert response2.status_code == 200, response2.text
        assert (await client.get("/account/commercial")).status_code == 401
        own = await client.get("/account/commercial", headers=alice)
        other = await client.get("/account/commercial", headers=bob)
        assert own.status_code == 200 and other.status_code == 200
        assert own.json()["credits_balance"] == 50
        assert own.json()["plan"] == "pro"
        assert other.json()["credits_balance"] == 0
        assert other.json()["plan"] == "free"
        assert "alice@example.com" not in str(other.json())
        response3 = await client.post("/admin/commercial/adjust-credits", headers=admin,
                                      json={"owner": ALICE, "delta": 50, "request_id": "http-credit-001"})
        assert response3.status_code == 200 and response3.json()["idempotent_replay"]
    identity._token_cache.clear()
