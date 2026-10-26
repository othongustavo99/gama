"""Fase 3C: planos e créditos internos para beta, sem cobrança externa.

Não cria assinatura financeira, não cobra OpenRouter e NÃO é acionado pelas
rotas de geração. O motor de cotas é opt-in para integração numa fase posterior.
Tudo persiste em DATA_DIR, com transações SQLite atômicas e ids idempotentes.
"""
from __future__ import annotations

import os
import re
import sqlite3
from contextlib import contextmanager
from functools import wraps
from uuid import uuid4
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
    # Múltiplas requisições podem abrir o banco simultaneamente. ALTERAR
    # journal_mode em toda conexão pode falhar com database is locked.
    try:
        db.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError as exc:
        if "locked" not in str(exc).lower():
            db.close()
            raise
        # Outra conexão está inicializando WAL; respeitar busy_timeout
        # para os comandos transacionais seguintes.
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
    db.execute("""CREATE TABLE IF NOT EXISTS feature_reservations (
        request_id TEXT PRIMARY KEY, owner TEXT NOT NULL, feature TEXT NOT NULL,
        day TEXT NOT NULL, status TEXT NOT NULL, credits INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""")
    db.execute("CREATE INDEX IF NOT EXISTS ix_feature_reservations_quota ON feature_reservations(owner,day,feature,status)")
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
        for feature, qty in db.execute(
            "SELECT feature,COUNT(*) FROM feature_reservations WHERE owner=? AND day=? "
            "AND status IN ('reserved','committed') GROUP BY feature", (owner, day),
        ).fetchall():
            counts[feature] = counts.get(feature, 0) + qty
        balance = _balance(db, owner)
    return {
        "account_id": owner,
        "plan": code,
        "plan_expires_at": expires,
        "credits_balance": balance,
        "limits": dict(CATALOG[code]),
        "usage_today": {feature: counts.get(feature, 0) for feature in CATALOG[code]},
        "day_utc": day,
        "enforcement_active": enforcement_enabled(),
        "payments_active": False,
        "limits_preview_only": not enforcement_enabled(),
        "note": ("Franquias beta aplicadas, sem pagamentos externos."
                 if enforcement_enabled() else "Franquias de teste; aplicação desativada."),
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
        for table in ("plan_assignments", "plan_events", "credit_events", "feature_usage", "feature_reservations"):
            changed += db.execute(f"DELETE FROM {table} WHERE owner=?", (owner,)).rowcount
    return bool(changed)


# Fase 3D - medição reversível com ativação explícita no Railway.
# Créditos são virtuais: nenhum pagamento ou compra é criado por este módulo.
class FeatureRequestAlreadyProcessed(CommercialError):
    pass


def enforcement_enabled() -> bool:
    return os.getenv("GAMA_COMMERCIAL_ENFORCEMENT", "0").strip().lower() in {"1", "true", "yes"}


def credit_overage_enabled() -> bool:
    return os.getenv("GAMA_COMMERCIAL_ALLOW_OVERAGE_CREDITS", "0").strip().lower() in {"1", "true", "yes"}


def _release_row(db: sqlite3.Connection, request_id: str, owner: str, now: str) -> None:
    row = db.execute("SELECT status, credits FROM feature_reservations WHERE request_id=? AND owner=?",
                     (request_id, owner)).fetchone()
    if row and row[0] == "reserved":
        db.execute("UPDATE feature_reservations SET status='released',updated_at=? WHERE request_id=? AND owner=?",
                   (now, request_id, owner))
        if row[1]:
            # O identificador de estorno não pode colidir com concessões manuais.
            db.execute("INSERT OR IGNORE INTO credit_events VALUES(?,?,?,?,?)",
                       ("refund:" + request_id, owner, row[1], "estorno_reserva_beta", now))


def reserve_feature(owner: str, feature: str, request_id: str) -> dict | None:
    """Reserva idempotente e atômica. Sem efeito com enforcement desligado.

    Em replay pendente/concluído, bloqueia nova chamada (evita cobrança dupla).
    Reservas órfãs com mais de 36 horas são estornadas no próximo acesso;
    esse prazo NÃO garante retomada do trabalho remoto.
    """
    if not enforcement_enabled():
        return None
    from .identity import require_auth
    if not require_auth():
        raise CommercialError("Franquias comerciais exigem autenticação individual Google")
    owner, request_id = _check_owner(owner), _check_id(request_id)
    if feature not in CATALOG["free"]:
        raise CommercialError("Funcionalidade desconhecida")
    now = _now()
    stamp, day = now.isoformat(), now.date().isoformat()
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        _check_owner(owner)
        stale_cutoff = (now - timedelta(hours=36)).isoformat()
        stale = db.execute("SELECT request_id,owner FROM feature_reservations WHERE status='reserved' "
                           "AND created_at<?", (stale_cutoff,)).fetchall()
        for old_id, old_owner in stale:
            _release_row(db, old_id, old_owner, stamp)
        existing = db.execute("SELECT owner,feature,status FROM feature_reservations WHERE request_id=?",
                              (request_id,)).fetchone()
        if existing and existing[:2] != (owner, feature):
            raise CommercialError("Identificador de operação reutilizado em outra conta ou recurso")
        if existing:
            raise FeatureRequestAlreadyProcessed("Esta operação já foi iniciada. Consulte o histórico antes de reenviar.")
        plan, _ = _plan_row(db, owner, now)
        available = CATALOG[plan][feature]
        legacy_count = db.execute("SELECT COUNT(*) FROM feature_usage WHERE owner=? AND feature=? AND day=?",
                                  (owner, feature, day)).fetchone()[0]
        new_count = db.execute("SELECT COUNT(*) FROM feature_reservations WHERE owner=? AND feature=? "
                               "AND day=? AND status IN ('reserved','committed')", (owner, feature, day)).fetchone()[0]
        credits = 0
        if legacy_count + new_count >= available:
            if not credit_overage_enabled() or _balance(db, owner) < 1:
                raise FeatureLimitReached("Sua franquia beta de %s acabou. Consulte seu plano ou tente amanhã (UTC)." % feature)
            credits = 1
            db.execute("INSERT INTO credit_events VALUES(?,?,?,?,?)",
                       ("spend:" + request_id, owner, -credits, "excedente_beta_" + feature, stamp))
        db.execute("INSERT INTO feature_reservations VALUES(?,?,?,?,?,?,?,?)",
                   (request_id, owner, feature, day, "reserved", credits, stamp, stamp))
    return {"request_id": request_id, "feature": feature, "credits_reserved": credits}


def finalize_feature(owner: str, reservation: dict | None, *, provider_contacted: bool = False,
                     delivered: bool = False) -> bool:
    """Confirma tentativa que pode ter gerado custo, ou estorna antes do provedor.

    Chamadas de IA iniciadas não são estornadas automaticamente em erro remoto:
    o provedor pode ter cobrado mesmo sem devolver artefato.
    """
    if not reservation:
        return False
    request_id = _check_id(reservation["request_id"])
    with _connect() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT owner,status FROM feature_reservations WHERE request_id=?", (request_id,)).fetchone()
        if not row or row[0] != owner or row[1] != "reserved":
            return False
        if provider_contacted or delivered:
            db.execute("UPDATE feature_reservations SET status='committed',updated_at=? WHERE request_id=?",
                       (_now().isoformat(), request_id))
        else:
            _release_row(db, request_id, owner, _now().isoformat())
    return True


@contextmanager
def artifact_quota(owner: str, request_id: str | None = None):
    """Aplica franquia a artefatos criados por endpoints /artifacts/.

    Falhas antes de entregar um artefato estornam a reserva. Identificador
    X-Idempotency-Key enviado pelo cliente evita repetição de operações.
    """
    hold = reserve_feature(owner, "artifact", request_id or uuid4().hex)
    try:
        yield hold
    except BaseException:
        finalize_feature(owner, hold, provider_contacted=False)
        raise
    else:
        finalize_feature(owner, hold, delivered=True)


def artifact_route(fn):
    """Decorator abaixo de @router.post; conserva a assinatura para FastAPI."""
    @wraps(fn)
    async def wrapped(*args, **kwargs):
        owner = kwargs.get("user_id")
        if not enforcement_enabled():
            return await fn(*args, **kwargs)
        if not owner:
            raise CommercialError("Conta autenticada obrigatória para usar franquias")
        # Chamadas antigas sem chave recebem um ID novo. Para replay seguro,
        # clientes devem fornecer X-Idempotency-Key estável por criação.
        try:
            with artifact_quota(owner, kwargs.get("idempotency_key")):
                return await fn(*args, **kwargs)
        except FeatureLimitReached as exc:
            from fastapi import HTTPException
            raise HTTPException(429, str(exc)) from exc
        except FeatureRequestAlreadyProcessed as exc:
            from fastapi import HTTPException
            raise HTTPException(409, str(exc)) from exc
        except CommercialError as exc:
            from fastapi import HTTPException
            raise HTTPException(403, str(exc)) from exc
    return wrapped
