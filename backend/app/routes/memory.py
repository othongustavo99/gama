"""CRUD da memória de longo prazo — isolada por X-User-Id / user_id."""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ..core.memory import get_store

router = APIRouter(prefix="/memory", tags=["memory"])


def _uid(
    x_user_id: Optional[str] = None,
    user_id: Optional[str] = None,
) -> str:
    uid = (x_user_id or user_id or "default").strip() or "default"
    return uid


class FactIn(BaseModel):
    text: str = Field(min_length=2, max_length=2000)


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
