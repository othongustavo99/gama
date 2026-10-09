"""CRUD da memória de longo prazo — isolada por X-User-Id / user_id."""

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


@router.post("/migrate")
async def migrate(body: MigrateIn):
    """Mescla a memória de um id antigo no id atual (usado pelo app após login Google)."""
    return migrate_memory(body.from_user_id, body.to_user_id)


@router.get("/prompt")
async def memory_prompt(
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    """Diagnóstico: mostra exatamente o bloco de memória injetado no prompt."""
    store = get_store(_uid(x_user_id))
    return {"user_id": store.user_id, "block": store.as_prompt_block()}


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
    fact = store.add_fact(body.text.strip(), source="user")
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
