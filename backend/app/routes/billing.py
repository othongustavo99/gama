"""3G: endpoints de pré-validação; NÃO ativam pagamentos ou planos."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..core import store_billing
from ..core.identity import current_user_id, require_auth

router = APIRouter(prefix='/account/billing', tags=['billing-preparation'])


def _user(user_id: str = Depends(current_user_id)) -> str:
    if not require_auth():
        raise HTTPException(403, 'Compras exigem autenticação Google individual')
    return user_id


class PlaySubscription(BaseModel):
    purchase_token: str = Field(min_length=16, max_length=4096)


def _translate(exc: store_billing.BillingError) -> HTTPException:
    if isinstance(exc, store_billing.BillingUnavailable):
        return HTTPException(503, str(exc))
    if isinstance(exc, store_billing.BillingConflict):
        return HTTPException(409, str(exc))
    return HTTPException(403, str(exc))


@router.get('/status')
async def billing_status(user_id: str = Depends(_user)):
    return {**store_billing.readiness(), 'account_authenticated': bool(user_id)}


@router.get('/play/catalog')
async def play_catalog(user_id: str = Depends(_user)):
    return store_billing.product_catalog()


@router.get('/play/account-binding')
async def play_account_binding(user_id: str = Depends(_user)):
    try:
        return store_billing.account_binding(user_id)
    except store_billing.BillingError as exc:
        raise _translate(exc) from exc


@router.post('/play/verify')
async def play_verify(payload: PlaySubscription, user_id: str = Depends(_user)):
    try:
        return await store_billing.verify_subscription(user_id, payload.purchase_token)
    except store_billing.BillingError as exc:
        raise _translate(exc) from exc


@router.get('/play/history')
async def play_history(user_id: str = Depends(_user)):
    try:
        return {'checks': store_billing.history(user_id), 'payments_active': store_billing.entitlements_enabled()}
    except store_billing.BillingError as exc:
        raise _translate(exc) from exc
