"""Administração comercial autenticada: indicadores agregados e operações beta.

A API não enumera contas e nunca confia em owner informado por usuários comuns.
"""
from __future__ import annotations

import os
import re

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from ..core import play_reconciliation

from ..core.commercial_metrics import media_quota_overview, overview
from ..core.usage_ledger import overview as cost_overview
from ..core.commercial_plans import (
    CommercialError, public_catalog, assign_plan, adjust_credits,
    account_snapshot, enforcement_enabled,
)
from ..core.identity import canonical_google_user_id, current_user_id, require_auth

router = APIRouter(prefix="/admin", tags=["commercial-admin"])


def _allowed_users() -> set[str]:
    # Allowlist obrigatória; vazia desabilita o painel.
    raw = os.getenv("GAMA_ADMIN_GOOGLE_EMAILS", "")
    accounts = set()
    for email in raw.replace(";", ",").split(","):
        email = email.strip().lower()
        if email and email.count("@") == 1 and " " not in email:
            accounts.add(canonical_google_user_id(google_id="", email=email))
    return accounts


async def require_admin(user_id: str = Depends(current_user_id)) -> str:
    # Nunca autoriza a identificação legada via X-User-Id.
    if not require_auth() or user_id not in _allowed_users():
        raise HTTPException(status_code=403, detail="Acesso administrativo não autorizado")
    return user_id


@router.get("/access")
async def admin_access(_admin: str = Depends(require_admin)):
    """Sonda mínima para habilitar navegação; não expõe allowlist ou contas."""
    from ..core.store_billing import entitlements_enabled
    return {"is_admin": True, "payments_active": entitlements_enabled()}


def _billing_enabled() -> bool:
    from ..core.store_billing import entitlements_enabled
    return entitlements_enabled()


@router.get("/overview")
async def commercial_overview(days: int = Query(default=7, ge=1, le=30), _admin: str = Depends(require_admin)):
    return {
        **overview(days),
        "media_reservations": media_quota_overview(days),
        "media_reservations_note": "Reservations may include failed attempts; not confirmed provider costs.",
        "currency": None,
        "provider_cost_total": None,
        "billing_enabled": _billing_enabled(),
        "provider_usage": cost_overview(days),
    }


class PlanAssignment(BaseModel):
    owner: str = Field(min_length=10, max_length=150)
    plan: str
    request_id: str = Field(min_length=8, max_length=80)
    duration_days: int | None = Field(default=None, ge=1, le=365)


class CreditAdjustment(BaseModel):
    owner: str = Field(min_length=10, max_length=150)
    delta: int = Field(ge=-100000, le=100000)
    request_id: str = Field(min_length=8, max_length=80)
    reason: str = Field(default="manual_beta", min_length=3, max_length=100)


@router.get("/commercial/catalog")
async def admin_commercial_catalog(_admin: str = Depends(require_admin)):
    return {"plans": public_catalog(), "payments_active": False, "limits_preview_only": not enforcement_enabled(), "enforcement_active": enforcement_enabled()}


@router.post("/commercial/assign-plan")
async def admin_assign_plan(payload: PlanAssignment, _admin: str = Depends(require_admin)):
    """Compatibilidade com API da Fase 3C: identificador canônico."""
    try:
        result = assign_plan(payload.owner, payload.plan, payload.request_id, duration_days=payload.duration_days)
        return {**result, "payments_active": False}
    except CommercialError as exc:
        raise HTTPException(409, str(exc)) from exc


@router.post("/commercial/adjust-credits")
async def admin_adjust_credits(payload: CreditAdjustment, _admin: str = Depends(require_admin)):
    try:
        result = adjust_credits(payload.owner, payload.delta, payload.request_id, reason=payload.reason)
        return {**result, "payments_active": False}
    except CommercialError as exc:
        raise HTTPException(409, str(exc)) from exc


# Operações da Fase 3F por e-mail exato, sem pedir ao administrador IDs técnicos.
# Nunca são rotas públicas, não fazem listagem de usuários ou pagamentos.
_EMAIL = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


class EmailTarget(BaseModel):
    email: str = Field(min_length=5, max_length=120)


def _owner_for_email(email: str) -> str:
    normalized = email.strip().lower()
    if not _EMAIL.fullmatch(normalized) or ".." in normalized:
        raise HTTPException(status_code=422, detail="Informe um e-mail Google válido")
    # Mesma transformação canônica validada em JWT Google do usuário.
    return canonical_google_user_id(google_id="", email=normalized)


@router.post("/commercial/account-by-email")
async def admin_account_by_email(payload: EmailTarget, _admin: str = Depends(require_admin)):
    try:
        result = account_snapshot(_owner_for_email(payload.email))
    except CommercialError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {
        **result,
        "lookup_note": "Conta calculada a partir do e-mail. Não comprova que esta pessoa já entrou na Gamma.",
    }


class EmailPlanAssignment(EmailTarget):
    plan: str
    request_id: str = Field(min_length=8, max_length=80)
    duration_days: int | None = Field(default=None, ge=1, le=365)


class EmailCreditAdjustment(EmailTarget):
    delta: int = Field(ge=-100000, le=100000)
    request_id: str = Field(min_length=8, max_length=80)
    reason: str = Field(min_length=3, max_length=100)


@router.post("/commercial/assign-plan-by-email")
async def admin_assign_plan_by_email(payload: EmailPlanAssignment, _admin: str = Depends(require_admin)):
    try:
        result = assign_plan(_owner_for_email(payload.email), payload.plan, payload.request_id,
                             duration_days=payload.duration_days)
        return {**result, "payments_active": False}
    except CommercialError as exc:
        raise HTTPException(409, str(exc)) from exc


@router.post("/commercial/adjust-credits-by-email")
async def admin_adjust_credits_by_email(payload: EmailCreditAdjustment, _admin: str = Depends(require_admin)):
    try:
        result = adjust_credits(_owner_for_email(payload.email), payload.delta, payload.request_id,
                                reason=payload.reason)
        return {**result, "payments_active": False}
    except CommercialError as exc:
        raise HTTPException(409, str(exc)) from exc


@router.get('/play/reconciliation')
async def admin_play_reconciliation(_admin: str = Depends(require_admin)):
    return play_reconciliation.overview()


@router.post('/play/reconcile')
async def admin_play_reconcile(limit: int = Query(default=20, ge=1, le=50),
                               _admin: str = Depends(require_admin)):
    try:
        return await play_reconciliation.reconcile_due(limit=limit, min_age_minutes=5)
    except play_reconciliation.billing.BillingUnavailable as exc:
        raise HTTPException(503, str(exc)) from exc


@router.get('/ops')
async def admin_ops(minutes: int = Query(default=15, ge=1, le=60),
                    _admin: str = Depends(require_admin)):
    """Operational measurements; no client data, passwords or token payloads."""
    from ..core.ops_observability import snapshot
    from ..storage_status import current_storage_status
    storage = current_storage_status()
    return {
        'runtime': snapshot(minutes),
        'storage': {
            'status': storage['status'],
            'writable': storage['writable'],
            'persistent': storage['persistent'],
        },
        'warning': 'In-process metrics reset after a restart; use Railway monitoring for long-term trends.',
    }
