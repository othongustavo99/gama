"""Painel administrativo somente leitura. Nunca expõe prompts ou lista de usuários."""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends, HTTPException, Query

from ..core.commercial_metrics import media_quota_overview, overview
from ..core.usage_ledger import overview as cost_overview
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
