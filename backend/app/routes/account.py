"""Autogestão de dados da conta, com autenticação Google obrigatória."""
from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel

from ..core.account_privacy import delete_account_data, deletion_status, start_new_account
from ..core.identity import require_auth, current_user_id
from ..core.usage_ledger import owner_overview
from ..core.commercial_plans import account_snapshot, CommercialError

router = APIRouter(prefix="/account", tags=["account"])


class DeleteConfirmation(BaseModel):
    confirmation: str


async def _account_id(authorization: str | None) -> str:
    # Nunca permitir operações destrutivas por X-User-Id (modo legado).
    if not require_auth():
        raise HTTPException(403, "Exclusão de conta exige autenticação Google ativa")
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Entre com sua conta Google")
    try:
        from ..core.identity import _verified_user_allow_deleted
        return await _verified_user_allow_deleted(authorization[7:].strip())
    except (PermissionError, ValueError) as exc:
        raise HTTPException(401, str(exc)) from exc
    except Exception as exc:
        raise HTTPException(503, "Falha temporária ao validar sessão Google") from exc


@router.get("/status")
async def status(authorization: str | None = Header(default=None)):
    uid = await _account_id(authorization)
    return {"status": deletion_status(uid)}


@router.delete("")
async def delete_account(body: DeleteConfirmation, authorization: str | None = Header(default=None)):
    uid = await _account_id(authorization)
    if body.confirmation != "EXCLUIR":
        raise HTTPException(400, "Confirme digitando EXCLUIR")
    result = delete_account_data(uid)
    if result["status"] != "deleted":
        raise HTTPException(503, detail={
            "message": "Exclusão iniciada, mas há dados pendentes; repita a operação mais tarde.",
            "incomplete_categories": result["incomplete_categories"],
        })
    return {"ok": True, **result}


@router.post("/start-new")
async def new_account(body: DeleteConfirmation, authorization: str | None = Header(default=None)):
    uid = await _account_id(authorization)
    if body.confirmation != "RECOMEÇAR":
        raise HTTPException(400, "Confirme digitando RECOMEÇAR")
    try:
        start_new_account(uid)
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "status": "active"}


@router.get("/usage")
async def my_usage(days: int = Query(default=7, ge=1, le=30), user_id: str = Depends(current_user_id)):
    """Resumo financeiro somente da conta autenticada, sem dados de outras contas."""
    return owner_overview(user_id, days)


@router.get("/commercial")
async def my_commercial_preview(user_id: str = Depends(current_user_id)):
    """Visualização por conta: sem pagamento e sem limites ativos nesta fase.

    Exige autenticação individual mesmo se o backend estiver em modo legado.
    """
    if not require_auth():
        raise HTTPException(403, "Informações comerciais exigem autenticação Google")
    try:
        return account_snapshot(user_id)
    except CommercialError as exc:
        raise HTTPException(403, str(exc)) from exc
