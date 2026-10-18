"""Daily per-user quotas for paid image and video generation."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from ..config import settings


class DailyQuotaExceeded(Exception):
    pass


def consume_daily_media_quota(user_id: str, media_type: str) -> None:
    """Atomically reserve one generation on the persistent DATA_DIR volume.

    A generation attempt is counted before contacting the provider because a
    provider failure can still incur a charge. Limit 0 disables that media type.
    """
    limits = {
        "image": settings.IMAGE_DAILY_LIMIT,
        "video": settings.VIDEO_DAILY_LIMIT,
    }
    if media_type not in limits:
        raise ValueError("tipo de mídia inválido")
    limit = limits[media_type]
    if limit <= 0:
        raise DailyQuotaExceeded(f"A geração de {media_type} está desativada por cota diária.")

    db_path = Path(settings.DATA_DIR) / "gama_media_quota.sqlite3"
    db_path.parent.mkdir(parents=True, exist_ok=True)
    day = datetime.now(timezone.utc).date().isoformat()
    try:
        with sqlite3.connect(db_path, timeout=10) as db:
            db.execute("PRAGMA busy_timeout = 10000")
            db.execute(
                "CREATE TABLE IF NOT EXISTS media_quota ("
                "user_id TEXT NOT NULL, media_type TEXT NOT NULL, day TEXT NOT NULL, "
                "used INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(user_id, media_type, day))"
            )
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT used FROM media_quota WHERE user_id=? AND media_type=? AND day=?",
                (user_id, media_type, day),
            ).fetchone()
            used = int(row[0]) if row else 0
            if used >= limit:
                db.rollback()
                raise DailyQuotaExceeded(
                    f"Você atingiu o limite de {limit} gerações de {media_type} por dia. Tente novamente amanhã."
                )
            db.execute(
                "INSERT INTO media_quota(user_id, media_type, day, used) VALUES(?,?,?,1) "
                "ON CONFLICT(user_id, media_type, day) DO UPDATE SET used=used+1",
                (user_id, media_type, day),
            )
            db.execute("DELETE FROM media_quota WHERE day < date('now', '-14 days')")
            db.commit()
    except DailyQuotaExceeded:
        raise
    except sqlite3.Error as exc:
        # Fail closed: never make paid requests when quota accounting is down.
        raise RuntimeError("Não foi possível verificar a cota diária de mídia.") from exc

