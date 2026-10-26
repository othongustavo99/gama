"""Journal de execuções de chat, persistido em SQLite no DATA_DIR.

Não guarda prompts, conteúdo das respostas, chaves nem IDs Google em claro.
Não é uma fila distribuída: reinícios do backend podem interromper execuções,
mas o usuário recebe o estado real e pode encontrar entregas já persistidas.
"""
from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from contextlib import contextmanager
from typing import Any

_LOCK = threading.RLock()
_ID = re.compile(r"^[a-f0-9]{32}$")
_STATUSES = frozenset({"running", "completed", "failed", "cancelled", "interrupted"})
_STALE_SECONDS = 120
_RETENTION_DAYS = 14


def _db_file() -> Path:
    base = Path(os.environ["DATA_DIR"]) if os.getenv("DATA_DIR") else Path(__file__).resolve().parents[2] / "data"
    base.mkdir(parents=True, exist_ok=True)
    return base / "gama_long_jobs.sqlite3"


@contextmanager
def _transaction():
    db = _connect()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def _owner(user_id: str) -> str:
    if not isinstance(user_id, str) or not user_id:
        raise ValueError("Identidade inválida")
    return hashlib.sha256(user_id.encode("utf-8")).hexdigest()


def _connect() -> sqlite3.Connection:
    db = sqlite3.connect(str(_db_file()), timeout=15)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=15000")
    db.execute("""CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY, owner TEXT NOT NULL,
        kind TEXT NOT NULL, status TEXT NOT NULL, phase TEXT NOT NULL,
        conversation_id TEXT NOT NULL, message_id TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        artifact_id TEXT NOT NULL DEFAULT '', filename TEXT NOT NULL DEFAULT '',
        error TEXT NOT NULL DEFAULT ''
    )""")
    db.execute("CREATE INDEX IF NOT EXISTS idx_jobs_owner ON jobs(owner, created_at DESC)")
    return db


def _public(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
    keys = ("id", "kind", "status", "phase", "conversation_id", "message_id",
            "created_at", "updated_at", "artifact_id", "filename", "error")
    result = {key: row[key] for key in keys}
    if result["status"] == "running" and int(time.time()) - int(result["updated_at"]) > _STALE_SECONDS:
        # Não afirmar que concluiu ou falhou: um worker pode ter reiniciado.
        result["status"] = "interrupted"
        result["phase"] = "connection_lost"
    return result


def start(user_id: str, *, conversation_id: str = "", message_id: str = "") -> dict[str, Any]:
    from .account_privacy import deletion_status
    if deletion_status(user_id) != "active":
        raise PermissionError("Conta excluída")
    now = int(time.time())
    job_id = uuid.uuid4().hex
    with _LOCK, _transaction() as db:
        db.execute("DELETE FROM jobs WHERE updated_at < ? AND status != 'running'",
                   (now - _RETENTION_DAYS * 86400,))
        db.execute("""INSERT INTO jobs
            (id,owner,kind,status,phase,conversation_id,message_id,created_at,updated_at)
            VALUES (?,?, 'chat', 'running', 'thinking', ?,?,?,?)""",
            (job_id, _owner(user_id), str(conversation_id)[:128], str(message_id)[:128], now, now))
    return get(user_id, job_id) or {}


def update(user_id: str, job_id: str, *, status: str | None = None,
           phase: str | None = None, artifact_id: str | None = None,
           filename: str | None = None, error: str | None = None) -> bool:
    if not _ID.fullmatch(job_id or ""):
        return False
    if status is not None and status not in _STATUSES:
        raise ValueError("Estado inválido")
    fields: list[str] = ["updated_at=?"]
    values: list[Any] = [int(time.time())]
    for key, val, max_len in (("status", status, 20), ("phase", phase, 60),
                              ("artifact_id", artifact_id, 64), ("filename", filename, 180),
                              ("error", error, 250)):
        if val is not None:
            fields.append(f"{key}=?")
            values.append(str(val)[:max_len])
    values.extend([job_id, _owner(user_id)])
    with _LOCK, _transaction() as db:
        return db.execute(f"UPDATE jobs SET {', '.join(fields)} WHERE id=? AND owner=?",
                          values).rowcount == 1


def get(user_id: str, job_id: str) -> dict[str, Any] | None:
    if not _ID.fullmatch(job_id or ""):
        return None
    with _LOCK, _transaction() as db:
        row = db.execute("SELECT * FROM jobs WHERE id=? AND owner=?", (job_id, _owner(user_id))).fetchone()
    return _public(row) if row else None


def list_jobs(user_id: str, limit: int = 40) -> list[dict[str, Any]]:
    with _LOCK, _transaction() as db:
        rows = db.execute("SELECT * FROM jobs WHERE owner=? ORDER BY created_at DESC LIMIT ?",
                          (_owner(user_id), min(max(int(limit), 1), 100))).fetchall()
    return [_public(row) for row in rows]


def delete_user(user_id: str) -> bool:
    """A limpeza de conta não remove jobs de outras identidades."""
    path = _db_file()
    if not path.exists():
        return False
    with _LOCK, _transaction() as db:
        return db.execute("DELETE FROM jobs WHERE owner=?", (_owner(user_id),)).rowcount > 0
