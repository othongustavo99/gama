"""CRUD da memória de longo prazo — isolada por X-User-Id / user_id."""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Query
from pydantic import BaseModel, Field

from ..core.memory import get_store, migrate_memory

router = APIRouter(prefix="/memory", tags=["memory"])

_LEGACY_PREFIXES = ("google_", "device_")


def _uid(x_user_id: Optional[str] = None, user_id: Optional[str] = None) -> str:
    return (x_user_id or user_id or "default").strip() or "default"


class FactIn(BaseModel):
    text: str = Field(min_length=2, max_length=2000)
    pinned: bool = False
    importance: Optional[int] = Field(default=None, ge=1, le=5)


class FactPatch(BaseModel):
    text: Optional[str] = Field(default=None, min_length=2, max_length=2000)
    pinned: Optional[bool] = None
    importance: Optional[int] = Field(default=None, ge=1, le=5)


class MigrateIn(BaseModel):
    from_user_id: str = Field(min_length=1, max_length=200)
    to_user_id: str = Field(min_length=1, max_length=200)


@router.post("/migrate")
async def migrate(
    body: MigrateIn,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    """Mescla a memória de um id legado no id atual (usado pelo app após login Google).

    Só aceita destino == X-User-Id e origem legada (google_*/device_*), para um
    chamador não conseguir sugar a memória de qualquer outro id.
    """
    to_id = _uid(x_user_id)
    if body.to_user_id != to_id:
        raise HTTPException(403, "O destino precisa ser o seu próprio id.")
    src = body.from_user_id
    if not src.startswith(_LEGACY_PREFIXES) or src.startswith("google_email_") or src == to_id:
        raise HTTPException(403, "Origem de migração não permitida.")
    return migrate_memory(src, to_id)


@router.get("/prompt")
async def memory_prompt(
    q: str = Query(default="", max_length=500),
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    """Diagnóstico: mostra o bloco de memória que seria injetado para a pergunta `q`."""
    store = get_store(_uid(x_user_id))
    return {"user_id": store.user_id, "query": q, "block": store.as_prompt_block(q)}


@router.get("/stats")
async def memory_stats(x_user_id: Optional[str] = Header(default=None, alias="X-User-Id")):
    return get_store(_uid(x_user_id)).stats()


@router.get("")
async def list_memory(x_user_id: Optional[str] = Header(default=None, alias="X-User-Id")):
    store = get_store(_uid(x_user_id))
    return {"user_id": store.user_id, "facts": store.list_facts()}


@router.post("")
async def add_memory(
    body: FactIn,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    try:
        fact = store.add_fact(body.text.strip(), source="user", pinned=body.pinned, importance=body.importance)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"ok": True, "fact": fact}


@router.patch("/{fact_id}")
async def patch_memory(
    fact_id: str,
    body: FactPatch,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    try:
        fact = store.update_fact(fact_id, text=body.text, pinned=body.pinned, importance=body.importance)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    if not fact:
        raise HTTPException(404, "Fato não encontrado")
    return {"ok": True, "fact": fact}


@router.delete("/{fact_id}")
async def delete_memory(
    fact_id: str,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_store(_uid(x_user_id))
    if not store.remove_fact(fact_id):
        raise HTTPException(404, "Fato não encontrado")
    return {"ok": True}


@router.delete("")
async def clear_memory(x_user_id: Optional[str] = Header(default=None, alias="X-User-Id")):
    get_store(_uid(x_user_id)).clear()
    return {"ok": True}
