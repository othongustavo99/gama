"""Regressão da Fase 1E: durabilidade, propriedade e exclusão do journal."""
import os
import sqlite3
import tempfile
import time
from unittest.mock import patch

from fastapi import HTTPException
import pytest

from app.core import account_privacy, long_jobs
from app.routes import jobs as jobs_route


@pytest.fixture
def journal_data(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    yield tmp_path


def test_persists_after_reconnect_and_isolates_accounts(journal_data):
    a = long_jobs.start("alice", conversation_id="conversation-1", message_id="reply-1")
    assert a["status"] == "running"
    assert a["kind"] == "chat"
    assert "alice" not in str(a)
    assert long_jobs.update("alice", a["id"], status="completed", phase="finished",
                            artifact_id="0123456789abcdef", filename="arquivo.zip")
    assert long_jobs.get("alice", a["id"])["artifact_id"] == "0123456789abcdef"
    assert long_jobs.get("bob", a["id"]) is None
    assert long_jobs.list_jobs("bob") == []
    assert not long_jobs.update("bob", a["id"], status="failed")
    assert long_jobs.get("alice", a["id"])["status"] == "completed"
    dbfile = journal_data / "gama_long_jobs.sqlite3"
    with sqlite3.connect(dbfile) as db:
        stored = db.execute("SELECT owner, status FROM jobs WHERE id=?", (a["id"],)).fetchone()
    assert stored[1] == "completed"
    assert stored[0] != "alice"


def test_stale_running_task_is_displayed_as_uncertain_not_complete(journal_data):
    a = long_jobs.start("alice")
    with sqlite3.connect(journal_data / "gama_long_jobs.sqlite3") as db:
        db.execute("UPDATE jobs SET updated_at=? WHERE id=?", (int(time.time()) - 180, a["id"]))
    assert long_jobs.get("alice", a["id"])["status"] == "interrupted"
    assert long_jobs.get("alice", a["id"])["phase"] == "connection_lost"
    assert long_jobs.update("alice", a["id"], phase="thinking")
    assert long_jobs.get("alice", a["id"])["status"] == "running"


def test_account_deletion_removes_only_owned_jobs(journal_data):
    alice = long_jobs.start("alice")
    bob = long_jobs.start("bob")
    account_privacy.delete_account_data("alice")
    assert long_jobs.get("alice", alice["id"]) is None
    assert long_jobs.get("bob", bob["id"]) is not None
    with pytest.raises(PermissionError):
        long_jobs.start("alice")


def test_rejects_invalid_id_and_invalid_status(journal_data):
    a = long_jobs.start("alice")
    assert long_jobs.get("alice", "../../secret") is None
    assert not long_jobs.update("alice", "../../secret", status="failed")
    with pytest.raises(ValueError):
        long_jobs.update("alice", a["id"], status="paid_again")


@pytest.mark.asyncio
async def test_route_observes_owner_and_returns_404(journal_data):
    entry = long_jobs.start("alice")
    assert (await jobs_route.job_list(user_id="alice"))["jobs"][0]["id"] == entry["id"]
    with pytest.raises(HTTPException) as exc:
        await jobs_route.job_detail(entry["id"], user_id="bob")
    assert exc.value.status_code == 404


@pytest.mark.asyncio
async def test_disconnected_stream_finishes_and_records_job(journal_data):
    """Closing the client stream must not discard its paid background response."""
    import asyncio
    import importlib
    import json
    from unittest.mock import AsyncMock, patch
    from app.models import ChatRequest, ChatMessage

    mod = importlib.import_module("app.routes.chat")
    release = asyncio.Event()
    begun = asyncio.Event()

    async def fake_stream(*, model, messages):
        yield json.dumps({"message": {"role": "assistant", "content": "Parte 1"}, "done": False}) + "\n"
        begun.set()
        await release.wait()
        yield json.dumps({"message": {"role": "assistant", "content": " e fim"}, "done": False}) + "\n"
        yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n"

    request = ChatRequest(
        model="openai/gpt-5.4-mini", chat_mode="conversar",
        assistant_message_id="phase1e-message", conversation_id="phase1e-chat",
        messages=[ChatMessage(role="user", content="Olá")],
        auto_memory=False, plugins={"memory": False, "web_search": False},
    )
    with (patch.object(mod.app_settings, "AGENT_TOOLS_ENABLED", False),
          patch.object(mod.gama, "build_messages", new=AsyncMock(return_value=(
              [{"role": "user", "content": "Olá"}], None, None, []))),
          patch.object(mod.llm, "stream_chat", new=fake_stream),
          patch.object(mod, "schedule_summary_refresh", return_value=None)):
        response = await mod.chat(request, user_id="phase1e-test")
        iterator = response.body_iterator
        await asyncio.wait_for(iterator.__anext__(), timeout=5)
        await iterator.aclose()
        await begun.wait()
        release.set()
        for _ in range(100):
            jobs = long_jobs.list_jobs("phase1e-test")
            if jobs and jobs[0]["status"] != "running":
                break
            await asyncio.sleep(.03)
        assert jobs[0]["status"] == "completed", jobs
        assert jobs[0]["message_id"] == "phase1e-message"
        assert jobs[0]["conversation_id"] == "phase1e-chat"
        # Let the background persistence finalize before ending the event loop.
        await asyncio.sleep(2.2)
