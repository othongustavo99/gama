"""Exclusão definitiva, isolamento e bloqueio de ressinc do dispositivo antigo."""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core import account_privacy, identity
from app.main import app


@pytest.fixture
def private_store(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("GAMA_REQUIRE_AUTH", "1")
    monkeypatch.delenv("GAMA_API_KEY", raising=False)
    # settings foi importado antes, configuração real não deve ser alterada
    from app.config import settings
    monkeypatch.setattr(settings, "GAMA_API_KEY", "")
    monkeypatch.setattr(settings, "REQUIRE_API_KEY", False)
    async def mock_verifier(token: str) -> str:
        if token == "alice":
            return "google_email_alice@example.com"
        if token == "bob":
            return "google_email_bob@example.com"
        raise PermissionError("token inválido")
    monkeypatch.setattr(identity, "_verifier", mock_verifier)
    identity._token_cache.clear()
    yield tmp_path
    identity._token_cache.clear()


def write(path: Path, data: str = "pessoal"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="utf-8")


def test_delete_only_authenticated_users_data_and_prevent_rehydration(private_store):
    base = private_store
    alice = "google_email_alice@example.com"
    bob = "google_email_bob@example.com"
    for uid in (alice, bob):
        write(base / "memory" / f"{uid}.json")
        write(base / "memory" / f"{uid}.json.bak")
        write(base / "memory_v3" / f"{uid}.sqlite3")
        write(base / "memory_v3" / f"{uid}.sqlite3-wal")
        write(base / "conversations" / uid / "first.json")
        write(base / "summaries" / f"{uid}.json")
        import hashlib
        owner = hashlib.sha256(uid.encode()).hexdigest()[:32]
        write(base / "video_jobs" / owner / "job.json")
        for folder, key in (("projects", "p"), ("artifacts", "a")):
            write(base / folder / (key + ("alice" if uid == alice else "bob")) / "meta.json", json.dumps({"user_id": uid}))
            write(base / folder / (key + ("alice" if uid == alice else "bob")) / "data.txt")
    with sqlite3.connect(base / "gama_media_quota.sqlite3") as db:
        db.execute("CREATE TABLE media_quota(user_id TEXT, media_type TEXT, day TEXT, used INTEGER)")
        db.executemany("INSERT INTO media_quota VALUES(?,?,?,?)", [(alice, "image", "2026", 3), (bob, "image", "2026", 2)])

    client = TestClient(app)
    assert client.request("DELETE", "/account", json={"confirmation": "EXCLUIR"}).status_code == 401
    assert client.request("DELETE", "/account", headers={"Authorization": "Bearer alice"}, json={"confirmation": "ERRADO"}).status_code == 400
    r = client.request("DELETE", "/account", headers={"Authorization": "Bearer alice"}, json={"confirmation": "EXCLUIR"})
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "deleted"
    assert not (base / "memory_v3" / f"{alice}.sqlite3").exists()
    assert not (base / "conversations" / alice).exists()
    assert not (base / "projects" / "palice").exists()
    assert not (base / "artifacts" / "aalice").exists()
    assert (base / "memory" / f"{bob}.json").exists()
    assert (base / "projects" / "pbob").exists()
    with sqlite3.connect(base / "gama_media_quota.sqlite3") as db:
        assert db.execute("SELECT user_id FROM media_quota").fetchall() == [(bob,)]

    assert client.get("/account/status", headers={"Authorization": "Bearer alice"}).json()["status"] == "deleted"
    # Depois de usar token alice numa rota normal, a decisão de excluir é
    # reavaliada inclusive quando o token de identidade estiver em cache.
    assert client.get("/conversations", headers={"Authorization": "Bearer alice"}).status_code == 403
    assert client.get("/conversations", headers={"Authorization": "Bearer bob"}).status_code == 200
    assert client.post("/account/start-new", headers={"Authorization": "Bearer alice"}, json={"confirmation": "RECOMEÇAR"}).status_code == 200
    assert client.get("/account/status", headers={"Authorization": "Bearer alice"}).json()["status"] == "active"
    assert client.get("/conversations", headers={"Authorization": "Bearer alice"}).status_code == 200
    # O recomeço não restaura nenhum dado de alice.
    assert not (base / "memory" / f"{alice}.json").exists()


def test_failed_cleanup_stays_blocked_and_can_retry(private_store, monkeypatch):
    uid = "google_email_alice@example.com"
    write(private_store / "memory" / f"{uid}.json")
    original = account_privacy._remove
    calls = {"failed": False}
    def flaky(target, base):
        if not calls["failed"] and target.name == f"{uid}.json":
            calls["failed"] = True
            raise OSError("filesystem busy")
        return original(target, base)
    monkeypatch.setattr(account_privacy, "_remove", flaky)
    client = TestClient(app)
    headers = {"Authorization": "Bearer alice"}
    response = client.request("DELETE", "/account", headers=headers, json={"confirmation": "EXCLUIR"})
    assert response.status_code == 503
    assert account_privacy.deletion_status(uid) == "deleting"
    assert client.get("/conversations", headers=headers).status_code == 403
    assert client.post("/account/start-new", headers=headers, json={"confirmation": "RECOMEÇAR"}).status_code == 409
    response = client.request("DELETE", "/account", headers=headers, json={"confirmation": "EXCLUIR"})
    assert response.status_code == 200
    assert not (private_store / "memory" / f"{uid}.json").exists()


def test_symlink_cannot_escape_own_data_dir(private_store, tmp_path):
    uid = "google_email_alice@example.com"
    outside = private_store.parent / (private_store.name + "-private")
    outside.mkdir()
    secret = outside / "secret.json"
    secret.write_text("segredo")
    (private_store / "memory").mkdir()
    (private_store / "memory" / f"{uid}.json").symlink_to(secret)
    result = account_privacy.delete_account_data(uid)
    assert result["status"] == "deleting"
    assert secret.read_text() == "segredo"


def test_deleted_account_cannot_save_late_video_or_artifact(private_store):
    """Um job já iniciado não pode repovoar vídeo/ZIP após exclusão."""
    from app.core.video_jobs import create_job
    from app.core.document_builder.store import save_artifact
    uid = "google_email_alice@example.com"
    account_privacy.delete_account_data(uid)
    with pytest.raises(PermissionError):
        create_job(uid)
    with pytest.raises(PermissionError):
        save_artifact(kind="zip", filename="output.zip", data=b"x", user_id=uid)
