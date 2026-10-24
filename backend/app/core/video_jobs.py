"""Registro durável de jobs de vídeo no DATA_DIR (Railway Volume).

Persistimos somente identificadores, metadados e progresso, jamais API keys.
O ID público não permite consultar jobs de outro usuário.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
import uuid
from pathlib import Path
from typing import Any

_LOCK = threading.RLock()
_ID = re.compile(r"^[a-f0-9]{16}$")
_MAX_PER_USER = 100


def _root() -> Path:
    base = Path(os.environ["DATA_DIR"]) if os.getenv("DATA_DIR") else Path(__file__).resolve().parents[2] / "data"
    folder = base / "video_jobs"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _folder(user_id: str) -> Path:
    owner = hashlib.sha256(user_id.encode("utf-8")).hexdigest()[:32]
    result = _root() / owner
    result.mkdir(parents=True, exist_ok=True)
    return result


def _file(user_id: str, job_id: str) -> Path:
    if not _ID.fullmatch(job_id):
        raise ValueError("ID de trabalho inválido")
    return _folder(user_id) / f"{job_id}.json"


def create_job(user_id: str, *, conversation_id: str | None = None) -> dict[str, Any]:
    now = int(time.time())
    item = {
        "job_id": uuid.uuid4().hex[:16],
        "status": "submitting",
        "created_at": now,
        "updated_at": now,
        "conversation_id": str(conversation_id or "")[:120],
    }
    with _LOCK:
        folder = _folder(user_id)
        old = sorted(folder.glob("*.json"), key=lambda p: p.stat().st_mtime)
        # Nunca descartar automaticamente um trabalho ativo.
        for path in old[:max(0, len(old) - _MAX_PER_USER + 1)]:
            try:
                content = json.loads(path.read_text(encoding="utf-8"))
                if content.get("status") in {"completed", "failed"}:
                    path.unlink(missing_ok=True)
            except (ValueError, OSError):
                continue
        _save(user_id, item)
    return item


def _save(user_id: str, item: dict[str, Any]) -> None:
    path = _file(user_id, str(item["job_id"]))
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
    os.replace(temp, path)


def get_job(user_id: str, job_id: str) -> dict[str, Any] | None:
    try:
        path = _file(user_id, job_id)
        if not path.is_file():
            return None
        result = json.loads(path.read_text(encoding="utf-8"))
        if result.get("job_id") != job_id:
            return None
        return result
    except (ValueError, OSError):
        return None


def update_job(user_id: str, job_id: str, **changes: Any) -> dict[str, Any] | None:
    with _LOCK:
        item = get_job(user_id, job_id)
        if item is None:
            return None
        protected = {"job_id", "created_at", "conversation_id"}
        item.update({key: value for key, value in changes.items() if key not in protected})
        item["updated_at"] = int(time.time())
        _save(user_id, item)
        return item


def list_jobs(user_id: str) -> list[dict[str, Any]]:
    folder = _folder(user_id)
    jobs = []
    for path in folder.glob("*.json"):
        job = get_job(user_id, path.stem)
        if job:
            jobs.append(public_job(job))
    jobs.sort(key=lambda v: v.get("created_at", 0), reverse=True)
    return jobs[:_MAX_PER_USER]


def public_job(job: dict[str, Any]) -> dict[str, Any]:
    # polling_url e provider_job_id nunca devem chegar ao aplicativo.
    return {key: job[key] for key in (
        "job_id", "status", "phase", "created_at", "updated_at",
        "conversation_id", "artifact_id", "filename", "error", "model",
    ) if key in job}
