"""Fase 3C: planos e créditos internos para beta, sem cobrança externa.

Não cria assinatura financeira, não cobra OpenRouter e NÃO é acionado pelas
rotas de geração. O motor de cotas é opt-in para integração numa fase posterior.
Tudo persiste em DATA_DIR, com transações SQLite atômicas e ids idempotentes.
"""
from __future__ import annotations

import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from contextlib import contextmanager
from pathlib import Path

# Franquias ILUSTRATIVAS para testes. Devem ser recalibradas antes de ativar
# qualquer limitação comercial com os custos reais coletados na Fase 3B.
CATALOG = {
    "free": {"chat": 30, "image": 2, "video": 0, "artifact": 3},
    "pro": {"chat": 150, "image": 10, "video": 2, "artifact": 20},
    "creator": {"chat": 400, "image": 25, "video": 5, "artifact": 100},
}
_USER = re.compile(r"^google_(?:email_)?[A-Za-z0-9_.@-]{1,120}$")
_REQUEST_ID = re.compile(r"^[A-Za-z0-9_-]{8,80}$")


class CommercialError(ValueError):
    pass


class InsufficientCredits(CommercialError):
    pass


class FeatureLimitReached(CommercialError):
    pass


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _check_owner(owner: str) -> str:
    if not isinstance(owner, str) or not _USER.fullmatch(owner):
        raise CommercialError("Conta Google inválida para administração comercial")
    from .account_privacy import deletion_status
    if deletion_status(owner) != "active":
        raise CommercialError("Conta excluída ou em exclusão não pode receber benefícios")
    return owner


def _check_id(request_id: str) -> str:
    if not isinstance(request_id, str) or not _REQUEST_ID.fullmatch(request_id):
        raise CommercialError("request_id inválido; use UUID ou identificador único de 8 a 80 caracteres")
    return request_id


def _path() -> Path:
    # Mesma convenção de persistência do livro de uso da Fase 3B.
    return Path(os.getenv("DATA_DIR", "/data")) / "gama_commercial_plans.sqlite3"


@contextmanager
def _connect():
    path = _path()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=15)
    db.execute("PRAGMA busy_timeout=15000")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("""CREATE TABLE IF NOT EXISTS plan_assignments (
        owner TEXT PRIMARY KEY, plan_code TEXT NOT NULL,
        expires_at TEXT, updated_at TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS plan_events (
        request_id TEXT PRIMARY KEY, owner TEXT NOT NULL, plan_code TEXT NOT NULL,
        duration_days INTEGER, expires_at TEXT, created_at TEXT NOT NULL)""")
    db.execute("CREATE INDEX IF NOT EXISTS ix_plan_events_owner ON plan_events(owner)")
    db.execute("""CREATE TABLE IF NOT EXISTS credit_events (
        request_id TEXT PRIMARY KEY, owner TEXT NOT NULL, delta INTEGER NOT NULL,
        reason TEXT NOT NULL, created_at TEXT NOT NULL)""")
    db.execute("CREATE INDEX IF NOT EXISTS ix_credit_events_owner ON credit_events(owner)")
    db.execute("""CREATE TABLE IF NOT EXISTS feature_usage (
        request_id TEXT PRIMARY KEY, owner TEXT NOT NULL, day TEXT NOT NULL,
        feature TEXT NOT NULL, created_at TEXT NOT NULL)""")
    db.execute("CREATE INDEX IF NOT EXISTS ix_feature_usage_owner ON feature_usage(owner,day,feature)")
    db.commit()
    try:
        yield db
        db.commit()
    except BaseException:
        db.rollback()
        raise
    finally:
        db.close()


def _plan_row(db: sqlite3.Connection, owner: str, now: datetime) -> tuple[str, str | None]:
    row = db.execute(
        "SELECT plan_code,expires_at FROM plan_assignments WHERE owner=?", (owner,)
    ).fetchone()
    if not row:
        return "free", None
    code, expiry = row
    if code not in CATALOG or (expiry and expiry <= now.isoformat()):
        return "free", None
    return code, expiry


def _balance(db: sqlite3.Connection, owner: str) -> int:
    return int(db.execute("SELECT COALESCE(SUM(delta),0) FROM credit_events WHERE owner=?", (owner,)).fetchone()[0])


def public_catalog() -> list[dict]:
    return [{"code": code, "daily_limits_preview": dict(limits)} for code, limits in CATALOG.items()]


def account_snapshot(owner: str) -> dict:
    owner = _check_owner(owner)
    now = _now()
    day = now.date().isoformat()
    with _connect() as db:
        code, expires = _plan_row(db, owner, now)
        counts = dict(db.execute(
            "SELECT feature,COUNT(*) FROM feature_usage WHERE owner=? AND day=? GROUP BY feature",
            (owner, day),
        ).fetchall())
        balance = _balance(db, owner)
    return {
        "account_id": owner,
        "plan": code,
        "plan_expires_at": expires,
        "credits_balance": balance,
        "limits": dict(CATALOG[code]),
        "usage_today": {feature: counts.get(feature, 0) for feature in CATALOG[code]},
        "day_utc": day,
        "enforcement_active": False,  # Ainda NÃO integrado às rotas de geração.
        "payments_active": False,
        "limits_preview_only": True,
        "note": "Franquias de teste, ainda não aplicadas às gerações nem vinculadas a cobranças.",
    }


def assign_plan(owner: str, plan_code: str, request_id: str, *, duration_days: int | None = None) -> dict:
    owner, request_id = _check_owner(owner), _check_id(request_id)
    if plan_code not in CATALOG:
        raise CommercialError("Plano desconhecido")
    if duration_days is not None and (not isinstance(duration_days, int) or isinstance(duration_days, bool) or not 1 <= duration_days <= 365):
        raise CommercialError("Duração deve estar entre 1 e 365 dias")
    if plan_code == "free" and duration_days is not None:
        raise CommercialError("Plano gratuito não possui duração")
    now = _now()
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        _check_owner(owner)
        previous = db.execute(
            "SELECT owner,plan_code,duration_days,expires_at FROM plan_events WHERE request_id=?",
            (request_id,),
        ).fetchone()
        if previous:
            if previous[:3] != (owner, plan_code, duration_days):
                raise CommercialError("request_id reutilizado para uma operação diferente")
            return {"plan": previous[1], "expires_at": previous[3], "idempotent_replay": True}
        expiry = (now + timedelta(days=duration_days)).isoformat() if duration_days else None
        db.execute("INSERT INTO plan_events VALUES(?,?,?,?,?,?)", (request_id, owner, plan_code, duration_days, expiry, now.isoformat()))
        db.execute("INSERT INTO plan_assignments VALUES(?,?,?,?) ON CONFLICT(owner) DO UPDATE SET plan_code=excluded.plan_code, expires_at=excluded.expires_at, updated_at=excluded.updated_at",
                   (owner, plan_code, expiry, now.isoformat()))
    return {"plan": plan_code, "expires_at": expiry, "idempotent_replay": False}


def adjust_credits(owner: str, delta: int, request_id: str, *, reason: str = "manual_beta") -> dict:
    """Crédito não monetário, apenas concessão administrativa/ajuste.

    Sem integração com pagamentos. Débitos internos podem ser feitos futuramente
    chamando esta função com autorização apropriada; nunca aceitos do usuário.
    """
    owner, request_id = _check_owner(owner), _check_id(request_id)
    if type(delta) is not int or delta == 0 or abs(delta) > 100_000:
        raise CommercialError("Ajuste deve ser inteiro, não zero, até 100000 créditos")
    if not isinstance(reason, str) or not 3 <= len(reason.strip()) <= 100:
        raise CommercialError("Informe um motivo entre 3 e 100 caracteres")
    reason = reason.strip()
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        _check_owner(owner)
        existing = db.execute(
            "SELECT owner,delta,reason FROM credit_events WHERE request_id=?", (request_id,)
        ).fetchone()
        if existing:
            if existing != (owner, delta, reason):
                raise CommercialError("request_id reutilizado para um ajuste diferente")
            return {"credits_balance": _balance(db, owner), "idempotent_replay": True}
        current = _balance(db, owner)
        if current + delta < 0:
            raise InsufficientCredits("Saldo insuficiente para este ajuste")
        db.execute("INSERT INTO credit_events VALUES(?,?,?,?,?)", (request_id, owner, delta, reason, _now().isoformat()))
        return {"credits_balance": current + delta, "idempotent_replay": False}


def claim_feature(owner: str, feature: str, request_id: str) -> dict:
    """Motor de cotas disponível para futuros fluxos, NÃO ligado às rotas.

    Uma operação aceita conta uma vez por request_id, com transação concorrente.
    Use somente após decidir regras de cobrança/estorno e sua integração.
    """
    owner, request_id = _check_owner(owner), _check_id(request_id)
    if feature not in CATALOG["free"]:
        raise CommercialError("Funcionalidade desconhecida")
    now = _now()
    day = now.date().isoformat()
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        _check_owner(owner)
        existing = db.execute("SELECT owner,feature FROM feature_usage WHERE request_id=?", (request_id,)).fetchone()
        if existing:
            if existing != (owner, feature):
                raise CommercialError("request_id reutilizado para outra funcionalidade ou conta")
            return {"accepted": True, "idempotent_replay": True}
        plan_code, _ = _plan_row(db, owner, now)
        limit = CATALOG[plan_code][feature]
        used = db.execute("SELECT COUNT(*) FROM feature_usage WHERE owner=? AND feature=? AND day=?", (owner, feature, day)).fetchone()[0]
        if used >= limit:
            raise FeatureLimitReached("Franquia de teste atingida para esta funcionalidade")
        db.execute("INSERT INTO feature_usage VALUES(?,?,?,?,?)", (request_id, owner, day, feature, now.isoformat()))
    return {"accepted": True, "idempotent_replay": False}


def delete_user(owner: str) -> bool:
    """Compatível com a exclusão por conta da Fase 1B e reexecução idempotente."""
    if not _path().is_file():
        return False
    changed = 0
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        for table in ("plan_assignments", "plan_events", "credit_events", "feature_usage"):
            changed += db.execute(f"DELETE FROM {table} WHERE owner=?", (owner,)).rowcount
    return bool(changed)
