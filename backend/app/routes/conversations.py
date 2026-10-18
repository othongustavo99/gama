"""CRUD de conversas sincronizadas por identidade validada no backend."""

from __future__ import annotations

import logging
import re
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..core.identity import current_user_id
from ..core.conversations import get_conversation_store
from ..llm import llm

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/conversations", tags=["conversations"])


class ConversationTitleRequest(BaseModel):
    model: Optional[str] = None
    user_message: str = Field(default="", max_length=8000)
    assistant_message: str = Field(default="", max_length=8000)


class MessageIn(BaseModel):
    id: str
    role: str
    content: str
    timestamp: Optional[str] = None
    conversationId: Optional[str] = None
    attachmentMetadataJson: Optional[str] = None
    variants: Optional[List[str]] = None
    selectedVariantIndex: Optional[int] = None
    isTruncated: bool = False
    sourcesJson: Optional[str] = Field(default=None, max_length=100_000)


class ConversationIn(BaseModel):
    id: str
    title: str = "Nova conversa"
    isPinned: bool = False
    createdAt: Optional[str] = None
    updatedAt: Optional[str] = None
    messages: List[MessageIn] = Field(default_factory=list)


class ConversationMetadataIn(BaseModel):
    title: Optional[str] = None
    isPinned: Optional[bool] = None
    updatedAt: Optional[str] = None


class DeleteMessagesIn(BaseModel):
    ids: List[str] = Field(default_factory=list, max_length=500)


@router.get("")
async def list_conversations(
    full: bool = True,
    user_id: str = Depends(current_user_id),
):
    store = get_conversation_store(user_id)
    items = store.list_conversations(include_messages=full)
    return {"user_id": store.user_id, "conversations": items, "count": len(items)}


@router.post("/title")
async def generate_conversation_title(
    body: ConversationTitleRequest,
    user_id: str = Depends(current_user_id),
):
    """Gera título de 3–5 palavras sem inserir a chamada como mensagem no chat."""
    user_text = (body.user_message or "").strip()
    assistant_text = (body.assistant_message or "").strip()
    if not user_text:
        raise HTTPException(status_code=400, detail="A primeira mensagem está vazia")

    # Limites curtos evitam gastar contexto com conversas longas só para titular.
    prompt_messages = [
        {
            "role": "system",
            "content": (
                "Crie um título para uma conversa de assistente de IA. "
                "Responda somente com 3 a 5 palavras em português, sem aspas, "
                "sem pontuação final, sem markdown e sem explicar o título. "
                "Use o tema principal da solicitação, não uma resposta genérica."
            ),
        },
        {
            "role": "user",
            "content": (
                "Primeira mensagem do usuário:\n" + user_text[:3500] +
                "\n\nResumo da primeira resposta:\n" + assistant_text[:1800]
            ),
        },
    ]
    model = llm.resolve_model(body.model)
    try:
        raw_title = await llm.chat_once(
            model,
            prompt_messages,
            timeout=22.0,
            max_tokens=40,
            temperature=0.2,
        )
    except Exception as exc:
        # Um título não deve tornar uma resposta do chat indisponível.
        logger.warning("title generation failed for %s: %s", user_id, type(exc).__name__)
        raw_title = ""

    title = re.sub(r"^[\s#*`\"']+|[\s#*`\"']+$", "", raw_title or "")
    title = re.sub(r"^(?:título|titulo)\s*[:：-]\s*", "", title, flags=re.IGNORECASE)
    words = re.findall(r"[^\W_]+(?:['’-][^\W_]+)*", title, flags=re.UNICODE)
    if len(words) < 3:
        fallback_text = re.sub(r"https?://\S+", "", user_text)
        words = re.findall(r"[^\W_]+(?:['’-][^\W_]+)*", fallback_text, flags=re.UNICODE)
    title = " ".join(words[:5]).strip() or "Nova conversa"
    return {"title": title, "user_id": user_id}


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


@router.patch("/{conversation_id}")
async def update_conversation_metadata(
    conversation_id: str,
    body: ConversationMetadataIn,
    user_id: str = Depends(current_user_id),
):
    store = get_conversation_store(user_id)
    existing = store.get(conversation_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Conversa não encontrada")
    payload = body.model_dump(exclude_none=True)
    existing.update(payload)
    existing["id"] = conversation_id
    store.upsert(existing)
    return {"ok": True}


@router.put("/{conversation_id}/messages/{message_id}")
async def upsert_conversation_message(
    conversation_id: str,
    message_id: str,
    body: MessageIn,
    user_id: str = Depends(current_user_id),
):
    if body.id != message_id:
        raise HTTPException(status_code=400, detail="id do path difere do body")
    try:
        item = get_conversation_store(user_id).upsert_message(
            conversation_id,
            {"updatedAt": body.timestamp},
            body.model_dump(),
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "conversation": item}


@router.post("/{conversation_id}/messages/delete")
async def delete_conversation_messages(
    conversation_id: str,
    body: DeleteMessagesIn,
    user_id: str = Depends(current_user_id),
):
    item = get_conversation_store(user_id).delete_messages(conversation_id, body.ids)
    if item is None:
        raise HTTPException(status_code=404, detail="Conversa não encontrada")
    return {"ok": True}


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
