"""CRUD da memória de longo prazo — isolada por X-User-Id / user_id.

Inclui endpoint de migração (Google login: ids legados → chave estável por e-mail).
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ..core.memory import get_store, migrate_memory

router = APIRouter(prefix="/memory", tags=["memory"])


def _uid(
    x_user_id: Optional[str] = None,
    user_id: Optional[str] = None,
) -> str:
    uid = (x_user_id or user_id or "default").strip() or "default"
    return uid


class FactIn(BaseModel):
    text: str = Field(min_length=2, max_length=2000)


class MigrateIn(BaseModel):
    from_user_id: str = Field(min_length=1, max_length=200)
    to_user_id: str = Field(min_length=1, max_length=200)


@router.get("")
async def list_memory(
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    return {
        "user_id": store.user_id,
        "facts": store.list_facts(),
    }


@router.post("")
async def add_memory(
    body: FactIn,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    try:
        fact = store.add_fact(body.text.strip(), source="user")
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return {"ok": True, "fact": fact}


@router.delete("/{fact_id}")
async def delete_memory(
    fact_id: str,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    ok = store.remove_fact(fact_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Fato não encontrado")
    return {"ok": True}


@router.delete("")
async def clear_memory(
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    store.clear()
    return {"ok": True}


@router.post("/migrate")
async def migrate(
    body: MigrateIn,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    """
    Mescla memória de from_user_id → to_user_id (sem duplicar texto).
    Usado pelo app após login Google para unificar ids legados
    (google_<numeric>) na chave estável google_email_*.
    """
    # Segurança básica: só permite migrar para o user_id do header
    # (evita que um cliente mescle memória de terceiros).
    caller = _uid(x_user_id)
    to_id = (body.to_user_id or "").strip()
    from_id = (body.from_user_id or "").strip()
    if not to_id or not from_id:
        raise HTTPException(status_code=400, detail="from_user_id e to_user_id obrigatórios")
    if to_id != caller and caller not in {"default", ""}:
        # Permite se o header já é o destino; senão rejeita.
        raise HTTPException(
            status_code=403,
            detail="Migração só permitida para o próprio X-User-Id",
        )
    result = migrate_memory(from_id, to_id)
    return result
