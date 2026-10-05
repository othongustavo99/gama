"""CRUD de conversas sincronizadas — isoladas por X-User-Id."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ..core.conversations import get_conversation_store

router = APIRouter(prefix="/conversations", tags=["conversations"])


def _uid(x_user_id: Optional[str] = None) -> str:
    return (x_user_id or "default").strip() or "default"


class MessageIn(BaseModel):
    id: str
    role: str
    content: str
    timestamp: Optional[str] = None
    conversationId: Optional[str] = None


class ConversationIn(BaseModel):
    id: str
    title: str = "Nova conversa"
    isPinned: bool = False
    createdAt: Optional[str] = None
    updatedAt: Optional[str] = None
    messages: List[MessageIn] = Field(default_factory=list)


@router.get("")
async def list_conversations(
    full: bool = True,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_conversation_store(_uid(x_user_id))
    items = store.list_conversations(include_messages=full)
    return {
        "user_id": store.user_id,
        "conversations": items,
        "count": len(items),
    }


@router.get("/{conversation_id}")
async def get_conversation(
    conversation_id: str,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_conversation_store(_uid(x_user_id))
    item = store.get(conversation_id)
    if not item:
        raise HTTPException(status_code=404, detail="Conversa não encontrada")
    return item


@router.put("/{conversation_id}")
async def upsert_conversation(
    conversation_id: str,
    body: ConversationIn,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    if body.id != conversation_id:
        raise HTTPException(status_code=400, detail="id do path difere do body")
    store = get_conversation_store(_uid(x_user_id))
    try:
        payload: Dict[str, Any] = body.model_dump()
        item = store.upsert(payload)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return {"ok": True, "conversation": item}


@router.delete("/{conversation_id}")
async def delete_conversation(
    conversation_id: str,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_conversation_store(_uid(x_user_id))
    ok = store.delete(conversation_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Conversa não encontrada")
    return {"ok": True}


@router.delete("")
async def clear_conversations(
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    store = get_conversation_store(_uid(x_user_id))
    store.clear()
    return {"ok": True}
