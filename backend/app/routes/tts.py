"""Proxy TTS → Fish Audio S2.1 Pro (chave só no servidor)."""

from __future__ import annotations

import logging
import os
from typing import Optional

import httpx
from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)
router = APIRouter(tags=["tts"])

FISH_URL = "https://api.fish.audio/v1/tts"


class TtsIn(BaseModel):
    text: str = Field(min_length=1, max_length=4000)
    format: str = "mp3"
    reference_id: Optional[str] = None


@router.post("/tts")
async def tts(body: TtsIn):
    key = os.getenv("FISH_AUDIO_API_KEY", "").strip()
    if not key:
        raise HTTPException(
            status_code=503,
            detail="FISH_AUDIO_API_KEY não configurada no backend",
        )

    payload = {
        "text": body.text.strip(),
        "format": body.format or "mp3",
    }
    ref = (body.reference_id or os.getenv("FISH_VOICE_ID", "")).strip()
    if ref:
        payload["reference_id"] = ref

    model = os.getenv("FISH_TTS_MODEL", "s2.1-pro").strip() or "s2.1-pro"

    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            r = await client.post(
                FISH_URL,
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/json",
                    "model": model,
                },
                json=payload,
            )
    except Exception as e:
        logger.exception("fish tts network")
        raise HTTPException(502, f"Fish Audio indisponível: {e}") from e

    if r.status_code >= 400:
        logger.warning("fish tts %s: %s", r.status_code, r.text[:300])
        raise HTTPException(
            status_code=502,
            detail=f"Fish Audio erro {r.status_code}: {r.text[:200]}",
        )

    media = "audio/mpeg" if (body.format or "mp3") == "mp3" else "audio/wav"
    return Response(content=r.content, media_type=media)
