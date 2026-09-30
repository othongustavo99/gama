from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..core.memory import memory_store


router = APIRouter(prefix="/memory", tags=["memory"])


class FactIn(BaseModel):
    text: str = Field(min_length=3, max_length=500)


@router.get("")
async def list_memory():
    return {"facts": memory_store.list_facts()}


@router.post("")
async def add_memory(body: FactIn):
    try:
        item = memory_store.add_fact(body.text, source="user")
        return {"ok": True, "fact": item}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.delete("/{fact_id}")
async def delete_memory(fact_id: str):
    ok = memory_store.remove_fact(fact_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Fato não encontrado")
    return {"ok": True}


@router.delete("")
async def clear_memory():
    memory_store.clear()
    return {"ok": True}
