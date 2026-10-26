"""Fase 3D: cotas transacionais, reversão, replay e rotas com opt-in."""
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest

from app.core import commercial_plans as cp
from app.core.account_privacy import delete_account_data

A = "google_email_alice@example.com"
B = "google_email_bob@example.com"


@pytest.fixture(autouse=True)
def temporary_store(monkeypatch, tmp_path):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("GAMA_REQUIRE_AUTH", "1")
    monkeypatch.delenv("GAMA_COMMERCIAL_ENFORCEMENT", raising=False)
    monkeypatch.delenv("GAMA_COMMERCIAL_ALLOW_OVERAGE_CREDITS", raising=False)


def activate(monkeypatch):
    monkeypatch.setenv("GAMA_COMMERCIAL_ENFORCEMENT", "1")


def test_disabled_does_not_touch_any_usage(monkeypatch):
    assert cp.reserve_feature(A, "chat", "disabled-chat-01") is None
    assert cp.reserve_feature(A, "video", "disabled-video-01") is None
    cp.finalize_feature(A, None, delivered=True)
    assert cp.account_snapshot(A)["usage_today"]["chat"] == 0
    assert not cp.account_snapshot(A)["enforcement_active"]


def test_atomic_quota_and_replay(monkeypatch):
    activate(monkeypatch)
    cp.assign_plan(A, "pro", "plan-pro-test-001")
    hold = cp.reserve_feature(A, "video", "video-operation-0001")
    assert hold
    with pytest.raises(cp.FeatureRequestAlreadyProcessed):
        cp.reserve_feature(A, "video", "video-operation-0001")
    cp.finalize_feature(A, hold, provider_contacted=True)
    with pytest.raises(cp.FeatureRequestAlreadyProcessed):
        cp.reserve_feature(A, "video", "video-operation-0001")
    hold2 = cp.reserve_feature(A, "video", "video-operation-0002")
    cp.finalize_feature(A, hold2, delivered=True)
    with pytest.raises(cp.FeatureLimitReached):
        cp.reserve_feature(A, "video", "video-operation-0003")
    assert cp.account_snapshot(A)["usage_today"]["video"] == 2
    assert cp.account_snapshot(B)["usage_today"]["video"] == 0
    assert cp.account_snapshot(A)["enforcement_active"] is True


def test_refund_if_never_called_provider(monkeypatch):
    activate(monkeypatch)
    a = cp.reserve_feature(A, "image", "image-test-00001")
    cp.finalize_feature(A, a, provider_contacted=False)
    assert cp.account_snapshot(A)["usage_today"]["image"] == 0
    # Um ID já usado não pode ser reaproveitado para gerar operação duvidosa.
    with pytest.raises(cp.FeatureRequestAlreadyProcessed):
        cp.reserve_feature(A, "image", "image-test-00001")
    b = cp.reserve_feature(A, "image", "image-test-00002")
    cp.finalize_feature(A, b, provider_contacted=False)
    assert cp.account_snapshot(A)["usage_today"]["image"] == 0


def test_overage_credits_and_refund_no_provider(monkeypatch):
    activate(monkeypatch)
    monkeypatch.setenv("GAMA_COMMERCIAL_ALLOW_OVERAGE_CREDITS", "1")
    cp.adjust_credits(A, 3, "grant-credits-0001", reason="crédito de teste")
    h1 = cp.reserve_feature(A, "video", "video-credit-0001")  # Free tem 0 vídeos
    assert h1["credits_reserved"] == 1
    assert cp.account_snapshot(A)["credits_balance"] == 2
    cp.finalize_feature(A, h1, provider_contacted=False)
    assert cp.account_snapshot(A)["credits_balance"] == 3
    assert not cp.finalize_feature(A, h1, delivered=True)
    h2 = cp.reserve_feature(A, "video", "video-credit-0002")
    cp.finalize_feature(A, h2, provider_contacted=True)
    assert cp.account_snapshot(A)["credits_balance"] == 2
    assert cp.account_snapshot(A)["usage_today"]["video"] == 1
    with pytest.raises(cp.CommercialError):
        cp.reserve_feature(B, "video", "video-credit-0002")


def test_concurrent_reservations_never_exceed_free_daily_chat(monkeypatch):
    activate(monkeypatch)
    def reserve(i):
        try:
            cp.reserve_feature(A, "chat", f"concurrent-chat-{i:04d}")
            return True
        except cp.FeatureLimitReached:
            return False
    with ThreadPoolExecutor(max_workers=10) as pool:
        results = list(pool.map(reserve, range(38)))
    assert sum(results) == 30
    assert cp.account_snapshot(A)["usage_today"]["chat"] == 30


def test_deletion_purges_new_reservations_only_for_target(monkeypatch):
    activate(monkeypatch)
    cp.reserve_feature(A, "image", "deletion-image-001")
    cp.reserve_feature(B, "image", "deletion-image-002")
    assert delete_account_data(A)["status"] == "deleted"
    assert cp.account_snapshot(B)["usage_today"]["image"] == 1
    with cp._connect() as db:
        assert db.execute("SELECT COUNT(*) FROM feature_reservations WHERE owner=?", (A,)).fetchone()[0] == 0


@pytest.mark.asyncio
async def test_artifact_endpoint_enforces_and_supports_stable_keys(monkeypatch):
    from app.core import identity
    from app.main import app
    from app.routes import artifacts
    activate(monkeypatch)
    async def verify(token):
        if token == "token-alice":
            return A
        if token == "token-bob":
            return B
        raise PermissionError("token inválido")
    monkeypatch.setattr(identity, "_verifier", verify)
    identity._token_cache.clear()
    monkeypatch.setattr(artifacts, "build_zip_from_files", lambda files, filename, user_id:
                        {"ok": True, "artifact_id": "test-artifact", "filename": filename})
    payload = {"files": {"a.txt": "teste"}}
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        header = {"Authorization": "Bearer token-alice", "X-Idempotency-Key": "artifact-build-001"}
        r = await c.post("/artifacts/zip/from-files", json=payload, headers=header)
        assert r.status_code == 200, r.text
        assert cp.account_snapshot(A)["usage_today"]["artifact"] == 1
        replay = await c.post("/artifacts/zip/from-files", json=payload, headers=header)
        assert replay.status_code == 409, replay.text
        assert cp.account_snapshot(A)["usage_today"]["artifact"] == 1
        bob = await c.post("/artifacts/zip/from-files", json=payload,
                           headers={"Authorization": "Bearer token-bob", "X-Idempotency-Key": "artifact-build-001"})
        assert bob.status_code == 403
    identity._token_cache.clear()


@pytest.mark.asyncio
async def test_chat_rejected_before_provider_when_limit_hit(monkeypatch):
    from app.core import identity
    from app.main import app
    activate(monkeypatch)
    async def verify(token):
        return A
    monkeypatch.setattr(identity, "_verifier", verify)
    identity._token_cache.clear()
    for i in range(30):
        cp.reserve_feature(A, "chat", f"previous-chat-{i:04d}")
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        result = await c.post("/chat", headers={"Authorization": "Bearer token"}, json={
            "model": "openai/gpt-4o-mini", "messages": [{"role": "user", "content": "Olá, tudo bem?"}],
            "chat_mode": "conversar", "assistant_message_id": "test-chat-limit-id",
        })
        assert result.status_code == 429, result.text
    identity._token_cache.clear()


def test_chat_internal_artifact_build_refunds_on_fail(monkeypatch):
    from app.routes import chat
    activate(monkeypatch)
    item = chat._commercial_artifact_build(A, lambda: {"artifact_id": "abc", "ok": True})
    assert item["artifact_id"] == "abc"
    assert cp.account_snapshot(A)["usage_today"]["artifact"] == 1
    with pytest.raises(ValueError, match="falhou"):
        chat._commercial_artifact_build(A, lambda: (_ for _ in ()).throw(ValueError("falhou")))
    assert cp.account_snapshot(A)["usage_today"]["artifact"] == 1


def test_requires_identity_mode_for_commercial_enforcement(monkeypatch):
    activate(monkeypatch)
    monkeypatch.setenv("GAMA_REQUIRE_AUTH", "0")
    with pytest.raises(cp.CommercialError, match="autenticação"):
        cp.reserve_feature(A, "chat", "identity-mode-test-01")


def test_36_hour_orphan_hold_is_released(monkeypatch):
    activate(monkeypatch)
    monkeypatch.setenv("GAMA_COMMERCIAL_ALLOW_OVERAGE_CREDITS", "1")
    cp.adjust_credits(A, 1, "grant-one-credit-01", reason="teste de recuperação")
    hold = cp.reserve_feature(A, "video", "stale-hold-video-01")
    assert cp.account_snapshot(A)["credits_balance"] == 0
    with cp._connect() as db:
        db.execute("UPDATE feature_reservations SET created_at='2000-01-01T00:00:00+00:00' WHERE request_id=?",
                   (hold["request_id"],))
    # Próxima reserva também libera estornos abandonados.
    cp.reserve_feature(A, "image", "next-image-0001")
    assert cp.account_snapshot(A)["credits_balance"] == 1
    assert cp.account_snapshot(A)["usage_today"]["video"] == 0
