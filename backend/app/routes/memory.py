"""CRUD da memória de longo prazo isolada pela identidade validada no backend."""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field

from ..core.identity import current_user_id, verify_google_legacy_user_id
from ..core.memory import get_store, migrate_memory

router = APIRouter(prefix="/memory", tags=["memory"])


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
    user_id: str = Depends(current_user_id),
    authorization: Optional[str] = Header(default=None, alias="Authorization"),
):
    """Migra somente a identidade Google numérica comprovadamente ligada ao token."""
    if body.to_user_id != user_id:
        raise HTTPException(403, "O destino precisa ser a sua identidade autenticada.")
    src = body.from_user_id.strip()
    if not src or src == user_id:
        return {"ok": True, "migrated": 0, "reason": "origem já é a identidade atual"}
    # O app antigo gravava google_<id-numérico>. Validamos que esse ID pertence
    # exatamente ao token apresentado; nunca aceitamos device_ ou IDs arbitrários.
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Migração exige token Google válido.")
    try:
        own_legacy_id = await verify_google_legacy_user_id(authorization[7:].strip())
    except PermissionError as exc:
        raise HTTPException(401, str(exc)) from exc
    except Exception as exc:
        raise HTTPException(503, "Não foi possível validar a conta Google para migração.") from exc
    if src != own_legacy_id:
        raise HTTPException(403, "A origem não pertence à conta autenticada.")
    result = migrate_memory(src, user_id)
    return {**result, "ok": True}




@router.get("/history")
async def memory_history(user_id: str = Depends(current_user_id)):
    store = get_store(user_id)
    return {"history": store.list_history() if hasattr(store, "list_history") else []}


@router.post("/history/{event_id}/undo")
async def undo_memory_change(event_id: str, user_id: str = Depends(current_user_id)):
    store = get_store(user_id)
    if not hasattr(store, "undo_event"):
        raise HTTPException(409, "Memória v3 desativada")
    try:
        return store.undo_event(event_id)
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc


@router.get("/episodes")
async def memory_episodes(q: str = Query(default="", max_length=300), user_id: str = Depends(current_user_id)):
    store = get_store(user_id)
    return {"episodes": store.search_episodes(q) if hasattr(store, "search_episodes") else []}


@router.get("/prompt")
async def memory_prompt(
    q: str = Query(default="", max_length=500),
    user_id: str = Depends(current_user_id),
):
    store = get_store(user_id)
    return {"user_id": store.user_id, "query": q, "block": store.as_prompt_block(q)}


@router.get("/stats")
async def memory_stats(user_id: str = Depends(current_user_id)):
    return get_store(user_id).stats()


@router.get("")
async def list_memory(user_id: str = Depends(current_user_id)):
    store = get_store(user_id)
    return {"user_id": store.user_id, "facts": store.list_facts()}


@router.post("")
async def add_memory(body: FactIn, user_id: str = Depends(current_user_id)):
    store = get_store(user_id)
    try:
        fact = store.add_fact(body.text.strip(), source="user", pinned=body.pinned, importance=body.importance)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"ok": True, "fact": fact}


@router.patch("/{fact_id}")
async def patch_memory(
    fact_id: str,
    body: FactPatch,
    user_id: str = Depends(current_user_id),
):
    store = get_store(user_id)
    try:
        fact = store.update_fact(fact_id, text=body.text, pinned=body.pinned, importance=body.importance)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    if not fact:
        raise HTTPException(404, "Fato não encontrado")
    return {"ok": True, "fact": fact}


@router.delete("/{fact_id}")
async def delete_memory(fact_id: str, user_id: str = Depends(current_user_id)):
    store = get_store(user_id)
    if not store.remove_fact(fact_id):
        raise HTTPException(404, "Fato não encontrado")
    event_id = None
    if hasattr(store, "list_history"):
        recent = store.list_history(3)
        event_id = next((e["event_id"] for e in recent if e["action"] == "DELETE" and e["fact_id"] == fact_id), None)
    return {"ok": True, "undo_event_id": event_id}


@router.delete("")
async def clear_memory(user_id: str = Depends(current_user_id)):
    get_store(user_id).clear()
    return {"ok": True}
