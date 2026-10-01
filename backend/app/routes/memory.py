from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ..core.memory import get_store

router = APIRouter(prefix="/memory", tags=["memory"])


class FactIn(BaseModel):
    text: str = Field(min_length=3, max_length=500)


def _uid(x_user_id: Optional[str]) -> str:
    return (x_user_id or "default").strip() or "default"


@router.get("")
async def list_memory(x_user_id: Optional[str] = Header(default=None)):
    store = get_store(_uid(x_user_id))
    return {"facts": store.list_facts(), "user_id": store.user_id}


@router.post("")
async def add_memory(
    body: FactIn,
    x_user_id: Optional[str] = Header(default=None),
):
    store = get_store(_uid(x_user_id))
    try:
        item = store.add_fact(body.text, source="user")
        return {"ok": True, "fact": item, "user_id": store.user_id}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.delete("/{fact_id}")
async def delete_memory(
    fact_id: str,
    x_user_id: Optional[str] = Header(default=None),
):
    store = get_store(_uid(x_user_id))
    ok = store.remove_fact(fact_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Fato não encontrado")
    return {"ok": True}


@router.delete("")
async def clear_memory(x_user_id: Optional[str] = Header(default=None)):
    store = get_store(_uid(x_user_id))
    store.clear()
    return {"ok": True, "user_id": store.user_id}
