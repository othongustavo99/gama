"""Armazenamento de artefatos gerados (ZIP/PDF) em DATA_DIR/artifacts."""

from __future__ import annotations

import json
import os
import shutil
import time
import uuid
from pathlib import Path
from typing import Any, Optional

_TTL_SEC = 12 * 3600  # 12h


def _root() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[3] / "data"
    p = base / "artifacts"
    p.mkdir(parents=True, exist_ok=True)
    return p


def new_artifact_id() -> str:
    return uuid.uuid4().hex[:16]


def artifact_dir(artifact_id: str) -> Path:
    safe = "".join(c for c in artifact_id if c.isalnum() or c in "-_")[:32]
    return _root() / safe


def save_artifact(
    *,
    kind: str,
    filename: str,
    data: bytes,
    meta: Optional[dict[str, Any]] = None,
    user_id: str = "default",
) -> dict[str, Any]:
    cleanup_old()
    aid = new_artifact_id()
    d = artifact_dir(aid)
    d.mkdir(parents=True, exist_ok=True)

    safe_name = Path(filename).name.replace("..", "_") or f"file.{kind}"
    path = d / safe_name
    path.write_bytes(data)

    info = {
        "artifact_id": aid,
        "kind": kind,
        "filename": safe_name,
        "size": len(data),
        "user_id": user_id,
        "created_at": time.time(),
        "path": str(path),
        **(meta or {}),
    }
    (d / "meta.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return info


def load_artifact(artifact_id: str) -> Optional[dict[str, Any]]:
    d = artifact_dir(artifact_id)
    meta_path = d / "meta.json"
    if not meta_path.exists():
        return None
    try:
        info = json.loads(meta_path.read_text(encoding="utf-8"))
        file_path = Path(info.get("path") or (d / info.get("filename", "")))
        if not file_path.exists():
            # try relative to dir
            file_path = d / info.get("filename", "")
        if not file_path.exists():
            return None
        info["path"] = str(file_path)
        info["bytes"] = file_path.read_bytes()
        return info
    except Exception:
        return None


def list_recent(user_id: Optional[str] = None, limit: int = 20) -> list[dict[str, Any]]:
    root = _root()
    items: list[dict[str, Any]] = []
    for child in root.iterdir():
        if not child.is_dir():
            continue
        meta = child / "meta.json"
        if not meta.exists():
            continue
        try:
            data = json.loads(meta.read_text(encoding="utf-8"))
            if user_id and data.get("user_id") != user_id:
                continue
            data.pop("path", None)
            items.append(data)
        except Exception:
            continue
    items.sort(key=lambda x: -float(x.get("created_at") or 0))
    return items[:limit]


def cleanup_old(max_age: float = _TTL_SEC) -> None:
    root = _root()
    now = time.time()
    for child in root.iterdir():
        if not child.is_dir():
            continue
        meta = child / "meta.json"
        try:
            if meta.exists():
                data = json.loads(meta.read_text(encoding="utf-8"))
                if now - float(data.get("created_at", 0)) > max_age:
                    shutil.rmtree(child, ignore_errors=True)
            elif now - child.stat().st_mtime > max_age:
                shutil.rmtree(child, ignore_errors=True)
        except Exception:
            pass


def work_dir(job_id: Optional[str] = None) -> Path:
    """Diretório temporário isolado para edição/recompactação."""
    jid = job_id or new_artifact_id()
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[3] / "data"
    p = base / "builder_work" / jid
    p.mkdir(parents=True, exist_ok=True)
    return p
