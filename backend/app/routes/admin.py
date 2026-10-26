"""Painel administrativo somente leitura. Nunca expõe prompts ou lista de usuários."""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..core.commercial_metrics import media_quota_overview, overview
from ..core.usage_ledger import overview as cost_overview
from ..core.commercial_plans import (
    CommercialError, public_catalog, assign_plan, adjust_credits, account_snapshot,
)
from ..core.identity import canonical_google_user_id, current_user_id, require_auth

router = APIRouter(prefix="/admin", tags=["commercial-admin"])


def _allowed_users() -> set[str]:
    # Explicit allowlist. Empty by default means admin endpoints are disabled.
    raw = os.getenv("GAMA_ADMIN_GOOGLE_EMAILS", "")
    accounts = set()
    for email in raw.replace(";", ",").split(","):
        email = email.strip().lower()
        if email and email.count("@") == 1 and " " not in email:
            accounts.add(canonical_google_user_id(google_id="", email=email))
    return accounts


async def require_admin(user_id: str = Depends(current_user_id)) -> str:
    # Never allow the legacy X-User-Id path to impersonate an admin.
    if not require_auth() or user_id not in _allowed_users():
        raise HTTPException(status_code=403, detail="Acesso administrativo não autorizado")
    return user_id


@router.get("/overview")
async def commercial_overview(days: int = Query(default=7, ge=1, le=30), _admin: str = Depends(require_admin)):
    return {
        **overview(days),
        "media_reservations": media_quota_overview(days),
        "media_reservations_note": "Reservations may include failed attempts; not confirmed provider costs.",
        "currency": None,
        "provider_cost_total": None,
        "billing_enabled": False,
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
    return {"plans": public_catalog(), "payments_active": False, "limits_preview_only": True}


@router.post("/commercial/assign-plan")
async def admin_assign_plan(payload: PlanAssignment, _admin: str = Depends(require_admin)):
    """Atribuição manual de beta. Não cria uma compra nem uma assinatura."""
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
