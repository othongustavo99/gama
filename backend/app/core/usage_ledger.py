"""Fase 3B: livro de custos informado pelo provedor, separado por conta.

Não calcula preços por tokens nem afirma custo zero quando o provedor omite usage.
Guarda apenas identificadores técnicos, contagens e valores financeiros;
nunca conteúdo de conversas, prompts, respostas, caminhos ou tokens OAuth.
"""
from __future__ import annotations

import contextvars
import hashlib
import os
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path

CURRENT_OWNER: contextvars.ContextVar[str | None] = contextvars.ContextVar("gama_usage_owner", default=None)
_UNIT = Decimal("1000000")


class BudgetExceeded(Exception):
    """A solicitação excederia o limite preventivo configurado."""


def owner() -> str | None:
    return CURRENT_OWNER.get()


def bind_owner(user_id: str):
    return CURRENT_OWNER.set(user_id)


def restore_owner(token) -> None:
    CURRENT_OWNER.reset(token)


def _db_path() -> Path:
    return Path(os.getenv("DATA_DIR", "/data")) / "gama_usage_ledger.sqlite3"


def _connect() -> sqlite3.Connection:
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=10)
    db.execute("PRAGMA busy_timeout=10000")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("""CREATE TABLE IF NOT EXISTS usage_events (
        event_id TEXT PRIMARY KEY, owner TEXT NOT NULL, day TEXT NOT NULL,
        provider TEXT NOT NULL, category TEXT NOT NULL, model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens INTEGER NOT NULL DEFAULT 0, cached_tokens INTEGER NOT NULL DEFAULT 0,
        cost_microunits INTEGER, created_at TEXT NOT NULL
    )""")
    db.execute("CREATE INDEX IF NOT EXISTS usage_owner_day ON usage_events(owner,day)")
    db.execute("CREATE INDEX IF NOT EXISTS usage_day ON usage_events(day)")
    db.execute("""CREATE TABLE IF NOT EXISTS pending_budget (
        reservation_id TEXT PRIMARY KEY, owner TEXT NOT NULL, day TEXT NOT NULL,
        reserved_microunits INTEGER NOT NULL, created_at TEXT NOT NULL
    )""")
    return db


def _count(value) -> int:
    try:
        return max(0, min(10**12, int(value or 0)))
    except (ValueError, TypeError, OverflowError):
        return 0


def _micro(value) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        dec = Decimal(str(value))
        if not dec.is_finite() or dec < 0 or dec > Decimal("1000000"):
            return None
        return int((dec * _UNIT).to_integral_value(rounding=ROUND_HALF_UP))
    except (InvalidOperation, ValueError, TypeError):
        return None


def _day() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def _allowed(user_id: str) -> bool:
    if not user_id:
        return False
    from .account_privacy import deletion_status
    return deletion_status(user_id) == "active"


def record_usage(
    user_id: str | None, *, provider: str, category: str, model: str,
    usage: dict | None = None, generation_id: str | None = None,
    cost=None,
) -> bool:
    """Idempotente por ID de geração do provedor quando disponível.

    Return True somente para uma linha inserida. 'unknown' é NULL, nunca zero.
    """
    if not user_id or not _allowed(user_id):
        return False
    values = usage if isinstance(usage, dict) else {}
    raw_cost = cost if cost is not None else values.get("cost")
    micro = _micro(raw_cost)
    details_in = values.get("prompt_tokens_details") or {}
    details_out = values.get("completion_tokens_details") or {}
    if not isinstance(details_in, dict):
        details_in = {}
    if not isinstance(details_out, dict):
        details_out = {}
    provider = str(provider or "unknown")[:40]
    category = str(category or "other")[:40]
    model = str(model or "unknown")[:180]
    if generation_id and len(str(generation_id)) <= 256:
        key = f"{provider}:{user_id}:{category}:{generation_id}"
        event_id = hashlib.sha256(key.encode()).hexdigest()
    else:
        event_id = secrets.token_hex(24)
    now = datetime.now(timezone.utc)
    with _connect() as db:
        if not _allowed(user_id):
            return False
        result = db.execute(
            "INSERT OR IGNORE INTO usage_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (event_id, user_id, now.date().isoformat(), provider, category, model,
             _count(values.get("prompt_tokens")), _count(values.get("completion_tokens")),
             _count(details_out.get("reasoning_tokens")), _count(details_in.get("cached_tokens")),
             micro, now.isoformat()),
        )
        # Delete old *unbilled* history only; financial records stay for audit until
        # the retention policy is decided (no arbitrary deletion of accounting).
        return result.rowcount > 0


def _daily_limit(key: str) -> int:
    """All budgets default OFF. Invalid values fail closed for configured keys."""
    raw = os.getenv(key, "").strip()
    if not raw:
        return 0
    amount = _micro(raw)
    if amount is None:
        raise ValueError(f"{key} inválido; informe valor positivo ou 0")
    return amount


def reserve_budget(user_id: str | None, *, category: str = "chat") -> str | None:
    """Reserva provisória atômica antes de chamada ao LLM.

    É uma contenção preventiva, não um teto absoluto do provedor: uma resposta
    pode custar mais do que a reserva. Zero/desconfigurado = desativado.
    """
    if not user_id:
        return None
    per_user = _daily_limit("GAMA_USER_DAILY_COST_LIMIT_USD")
    global_limit = _daily_limit("GAMA_GLOBAL_DAILY_COST_LIMIT_USD")
    if not per_user and not global_limit:
        return None
    if not _allowed(user_id):
        raise BudgetExceeded("Esta conta não está disponível.")
    names = {"llm": "GAMA_LLM_BUDGET_RESERVATION_USD", "image": "GAMA_IMAGE_BUDGET_RESERVATION_USD", "video": "GAMA_VIDEO_BUDGET_RESERVATION_USD"}
    defaults = {"llm": 500000, "image": 500000, "video": 2000000}
    reserve = _daily_limit(names.get(category, names["llm"])) or defaults.get(category, 500000)
    now = datetime.now(timezone.utc)
    day = now.date().isoformat()
    reservation_id = secrets.token_hex(20)
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        # Old reservations may remain after an interrupted process; retain them
        # until end of the UTC day to favor safety over extra availability.
        db.execute("DELETE FROM pending_budget WHERE day < ?", (day,))
        if not _allowed(user_id):
            raise BudgetExceeded("Esta conta não está disponível.")
        user_cost = db.execute("SELECT COALESCE(SUM(cost_microunits),0) FROM usage_events WHERE owner=? AND day=?",
                               (user_id, day)).fetchone()[0]
        user_pending = db.execute("SELECT COALESCE(SUM(reserved_microunits),0) FROM pending_budget WHERE owner=? AND day=?",
                                  (user_id, day)).fetchone()[0]
        global_cost = db.execute("SELECT COALESCE(SUM(cost_microunits),0) FROM usage_events WHERE day=?",
                                 (day,)).fetchone()[0]
        global_pending = db.execute("SELECT COALESCE(SUM(reserved_microunits),0) FROM pending_budget WHERE day=?",
                                    (day,)).fetchone()[0]
        if per_user and user_cost + user_pending + reserve > per_user:
            raise BudgetExceeded("Limite preventivo diário de IA atingido para esta conta.")
        if global_limit and global_cost + global_pending + reserve > global_limit:
            raise BudgetExceeded("Limite preventivo diário do serviço atingido. Tente amanhã.")
        db.execute("INSERT INTO pending_budget VALUES(?,?,?,?,?)",
                   (reservation_id, user_id, day, reserve, now.isoformat()))
    return reservation_id


def release_budget(reservation_id: str | None) -> None:
    if reservation_id:
        with _connect() as db:
            db.execute("DELETE FROM pending_budget WHERE reservation_id=?", (reservation_id,))


def overview(days: int = 7) -> dict:
    if not 1 <= days <= 30:
        raise ValueError("Escolha entre 1 e 30 dias")
    since = (datetime.now(timezone.utc).date() - timedelta(days=days - 1)).isoformat()
    with _connect() as db:
        rows = db.execute(
            "SELECT category,model,COUNT(*),SUM(input_tokens),SUM(output_tokens),"
            "SUM(reasoning_tokens),SUM(cached_tokens),SUM(cost_microunits),"
            "SUM(CASE WHEN cost_microunits IS NULL THEN 1 ELSE 0 END) "
            "FROM usage_events WHERE day>=? GROUP BY category,model ORDER BY category,model", (since,),
        ).fetchall()
        pending = db.execute("SELECT COUNT(*),COALESCE(SUM(reserved_microunits),0) "
                             "FROM pending_budget WHERE day=?", (_day(),)).fetchone()
    models = []
    for cat, model, calls, tin, tout, reason, cached, micro, unknown in rows:
        models.append({"category": cat, "model": model, "calls": calls,
                       "input_tokens": tin or 0, "output_tokens": tout or 0,
                       "reasoning_tokens": reason or 0, "cached_tokens": cached or 0,
                       "reported_cost_usd": round((micro or 0) / 1_000_000, 6),
                       "unknown_cost_calls": unknown or 0})
    return {
        "period_days": days,
        "reported_cost_usd": round(sum(m["reported_cost_usd"] for m in models), 6),
        "unknown_cost_calls": sum(m["unknown_cost_calls"] for m in models),
        "llm_and_media_calls": sum(m["calls"] for m in models),
        "models": models,
        "active_reservations": pending[0],
        "reserved_usd": round(pending[1] / 1_000_000, 6),
        "cost_note": "Somente custos informados pelo provedor. Valores ausentes não são zero. Não inclui tarifas de outros serviços.",
    }


def owner_overview(user_id: str, days: int = 7) -> dict:
    """Somente para usuário autenticado; nunca aceita owner de query/header arbitrário."""
    if not 1 <= days <= 30:
        raise ValueError("Escolha entre 1 e 30 dias")
    if not _allowed(user_id):
        raise PermissionError("Conta indisponível")
    start = (datetime.now(timezone.utc).date() - timedelta(days=days - 1)).isoformat()
    with _connect() as db:
        rows = db.execute(
            "SELECT category,COUNT(*),SUM(input_tokens),SUM(output_tokens),SUM(cost_microunits),"
            "SUM(CASE WHEN cost_microunits IS NULL THEN 1 ELSE 0 END) "
            "FROM usage_events WHERE owner=? AND day>=? GROUP BY category ORDER BY category",
            (user_id, start),
        ).fetchall()
    details = []
    for category, calls, tin, tout, micro, missing in rows:
        details.append({"category": category, "calls": calls, "input_tokens": tin or 0,
                        "output_tokens": tout or 0, "reported_cost_usd": round((micro or 0) / 1_000_000, 6),
                        "unknown_cost_calls": missing or 0})
    return {"period_days": days, "reported_cost_usd": round(sum(d["reported_cost_usd"] for d in details), 6),
            "unknown_cost_calls": sum(d["unknown_cost_calls"] for d in details), "categories": details,
            "cost_note": "Somente valores informados pelo provedor; operações sem valor podem ter sido cobradas."}


def delete_user(user_id: str) -> bool:
    if not _db_path().is_file():
        return False
    with _connect() as db:
        a = db.execute("DELETE FROM usage_events WHERE owner=?", (user_id,)).rowcount
        b = db.execute("DELETE FROM pending_budget WHERE owner=?", (user_id,)).rowcount
        return bool(a or b)
