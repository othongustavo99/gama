"""Índice temporário de projetos em DATA_DIR/projects."""

from __future__ import annotations

import json
import os
import shutil
import time
import uuid
from pathlib import Path
from typing import Any, Optional

_TTL_SEC = 6 * 3600  # 6h


def _root() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[3] / "data"
    p = base / "projects"
    p.mkdir(parents=True, exist_ok=True)
    return p


def new_project_id() -> str:
    return uuid.uuid4().hex[:16]


def project_dir(project_id: str) -> Path:
    safe = "".join(c for c in project_id if c.isalnum() or c in "-_")[:32]
    return _root() / safe


def save_meta(project_id: str, meta: dict[str, Any]) -> None:
    d = project_dir(project_id)
    d.mkdir(parents=True, exist_ok=True)
    meta = {**meta, "project_id": project_id, "updated_at": time.time()}
    (d / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def load_meta(project_id: str) -> Optional[dict[str, Any]]:
    path = project_dir(project_id) / "meta.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if time.time() - float(data.get("updated_at", 0)) > _TTL_SEC:
            # expirado
            return data  # ainda permite uso nesta sessão
        return data
    except Exception:
        return None


def workspace(project_id: str) -> Path:
    return project_dir(project_id) / "src"


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
                if now - float(data.get("updated_at", 0)) > max_age:
                    shutil.rmtree(child, ignore_errors=True)
            elif now - child.stat().st_mtime > max_age:
                shutil.rmtree(child, ignore_errors=True)
        except Exception:
            pass
