"""Fase 3A: telemetria agregável, sem prompts, conteúdo, tokens ou dados pessoais na API.

Estes contadores representam respostas HTTP iniciadas/aceitas. Não constituem
registros de custo, tokens usados, trabalho concluído ou faturamento.
Persistem em DATA_DIR; se o registro falhar, não interrompem o produto.
"""
from __future__ import annotations

import os
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

_DB_LOCK = threading.RLock()

KINDS = {
    "chat": "chat", "memory": "memory", "conversations": "sync",
    "extract": "uploads", "project": "projects", "artifacts": "artifacts",
    "media": "media", "jobs": "jobs", "tts": "voice", "search": "search",
}


def _db_path() -> Path:
    return Path(os.getenv("DATA_DIR", "/data")) / "gama_commercial_metrics.sqlite3"


def _connect() -> sqlite3.Connection:
    db_path = _db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(db_path, timeout=5)
    db.execute("PRAGMA busy_timeout=5000")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("""CREATE TABLE IF NOT EXISTS activity (
        day TEXT NOT NULL,
        owner TEXT NOT NULL,
        category TEXT NOT NULL,
        outcome TEXT NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, owner, category, outcome)
    )""")
    return db


@contextmanager
def _db():
    """Avoid concurrent SQLite DDL/writes and close every short-lived connection.

    This process-local lock protects telemetry only; never hold it across
    external provider calls or response streaming.
    """
    with _DB_LOCK:
        db = _connect()
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()


def classify(path: str) -> str | None:
    first = path.strip("/").split("/", 1)[0]
    return KINDS.get(first)


def outcome(status_code: int) -> str:
    if 200 <= status_code < 400:
        return "accepted"
    if 400 <= status_code < 500:
        return "client_error"
    return "server_error"


def record_request(owner: str, path: str, status_code: int, *, at: datetime | None = None) -> None:
    """1 request = 1 accepted/error; streaming may finish later or fail.

    Account-deletion check happens in authentication middleware, and we check
    again before recording to avoid recreating activity after deletion.
    """
    category = classify(path)
    if category is None or not owner:
        return
    from .account_privacy import deletion_status
    if deletion_status(owner) != "active":
        return
    moment = at or datetime.now(timezone.utc)
    day = moment.astimezone(timezone.utc).date().isoformat()
    with _db() as db:
        db.execute(
            "INSERT INTO activity(day,owner,category,outcome,requests) VALUES(?,?,?,?,1) "
            "ON CONFLICT(day,owner,category,outcome) DO UPDATE SET requests=requests+1",
            (day, owner, category, outcome(status_code)),
        )
        # Minimize retained identifiers and accumulated storage.
        db.execute("DELETE FROM activity WHERE day < ?", (
            (moment.astimezone(timezone.utc).date() - timedelta(days=30)).isoformat(),
        ))


def _date_limit(days: int) -> str:
    return (datetime.now(timezone.utc).date() - timedelta(days=days - 1)).isoformat()


def overview(days: int = 7) -> dict:
    if not 1 <= days <= 30:
        raise ValueError("Escolha entre 1 e 30 dias")
    start = _date_limit(days)
    # Opening the DB may create an empty, valid database.
    with _db() as db:
        rows = db.execute(
            "SELECT category,outcome,SUM(requests) FROM activity WHERE day>=? "
            "GROUP BY category,outcome ORDER BY category,outcome", (start,),
        ).fetchall()
        active = db.execute("SELECT COUNT(DISTINCT owner) FROM activity WHERE day>=?", (start,)).fetchone()[0]
        timeline = db.execute(
            "SELECT day,SUM(requests) FROM activity WHERE day>=? GROUP BY day ORDER BY day", (start,),
        ).fetchall()
    categories: dict[str, dict[str, int]] = {}
    for category, result, count in rows:
        categories.setdefault(category, {"accepted": 0, "client_error": 0, "server_error": 0})[result] = count
    return {
        "period_days": days,
        "since_utc": start,
        "active_users_in_period": active,
        "requests_total": sum(int(count) for _, _, count in rows),
        "categories": categories,
        "daily": [{"day": day, "requests": count} for day, count in timeline],
        "measurement": "HTTP requests, not generations completed, tokens or costs",
    }


def media_quota_overview(days: int = 7) -> dict:
    """Leitura agregada das reservas existentes; NÃO representa gasto comprovado."""
    path = Path(os.getenv("DATA_DIR", "/data")) / "gama_media_quota.sqlite3"
    if not path.is_file():
        return {"image": 0, "video": 0}
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=3) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='media_quota'").fetchone():
                return {"image": 0, "video": 0}
            rows = db.execute("SELECT media_type,SUM(used) FROM media_quota "
                              "WHERE day>=? GROUP BY media_type", (_date_limit(days),)).fetchall()
        totals = {"image": 0, "video": 0}
        for media_type, count in rows:
            if media_type in totals:
                totals[media_type] = int(count or 0)
        return totals
    except sqlite3.Error:
        return {"image": 0, "video": 0}


def delete_user(owner: str) -> bool:
    path = _db_path()
    if not path.is_file():
        return False
    with _db() as db:
        row = db.execute("DELETE FROM activity WHERE owner=?", (owner,))
        return row.rowcount > 0
