"""Webhook RTDN da Google Play, autenticado exclusivamente por OIDC Pub/Sub."""
from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request

from ..core import play_reconciliation as rtdn
from ..core.store_billing import BillingForbidden, BillingUnavailable, BillingError

router = APIRouter(prefix='/webhooks/google-play', tags=['billing-events'])


@router.post('/rtdn')
async def receive_rtdn(request: Request):
    # O Pub/Sub faz push para o endpoint. Não aceitar tokens Gamma aqui.
    try:
        await rtdn.authenticate_push(request.headers.get('authorization', ''))
        if int(request.headers.get('content-length') or 0) > 65536:
            raise HTTPException(413, 'Evento muito grande')
        body = await request.body()
        if len(body) > 65536:
            raise HTTPException(413, 'Evento muito grande')
        try:
            import json
            payload = json.loads(body)
        except (ValueError, UnicodeError) as exc:
            raise HTTPException(400, 'Notificação inválida') from exc
        if not isinstance(payload, dict):
            raise HTTPException(400, 'Notificação inválida')
        return await rtdn.process_push(payload)
    except BillingForbidden as exc:
        raise HTTPException(403, str(exc)) from exc
    except BillingUnavailable as exc:
        raise HTTPException(503, str(exc)) from exc
    except BillingError as exc:
        raise HTTPException(409, str(exc)) from exc
