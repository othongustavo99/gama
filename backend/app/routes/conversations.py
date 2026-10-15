"""CRUD de conversas sincronizadas por identidade validada no backend."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..core.identity import current_user_id
from ..core.conversations import get_conversation_store

router = APIRouter(prefix="/conversations", tags=["conversations"])


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
    user_id: str = Depends(current_user_id),
):
    store = get_conversation_store(user_id)
    items = store.list_conversations(include_messages=full)
    return {"user_id": store.user_id, "conversations": items, "count": len(items)}


@router.get("/{conversation_id}")
async def get_conversation(
    conversation_id: str,
    user_id: str = Depends(current_user_id),
):
    item = get_conversation_store(user_id).get(conversation_id)
    if not item:
        raise HTTPException(status_code=404, detail="Conversa não encontrada")
    return item


@router.put("/{conversation_id}")
async def upsert_conversation(
    conversation_id: str,
    body: ConversationIn,
    user_id: str = Depends(current_user_id),
):
    if body.id != conversation_id:
        raise HTTPException(status_code=400, detail="id do path difere do body")
    store = get_conversation_store(user_id)
    try:
        payload: Dict[str, Any] = body.model_dump()
        item = store.upsert(payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "conversation": item}


@router.delete("/{conversation_id}")
async def delete_conversation(
    conversation_id: str,
    user_id: str = Depends(current_user_id),
):
    ok = get_conversation_store(user_id).delete(conversation_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Conversa não encontrada")
    return {"ok": True}


@router.delete("")
async def clear_conversations(user_id: str = Depends(current_user_id)):
    get_conversation_store(user_id).clear()
    return {"ok": True}
