"""Proxy TTS → Fish Audio (baixa latência)."""

from __future__ import annotations

import logging
import os
import re
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


def _clean_text(text: str) -> str:
    t = text.strip()
    t = re.sub(r"```[\s\S]*?```", " ", t)
    t = re.sub(r"`[^`]+`", " ", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)
    t = re.sub(r"[#>*_~]{1,}", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t[:1500] if len(t) > 1500 else t


@router.post("/tts")
async def tts(body: TtsIn):
    key = os.getenv("FISH_AUDIO_API_KEY", "").strip()
    if not key:
        raise HTTPException(503, detail="FISH_AUDIO_API_KEY não configurada")

    text = _clean_text(body.text)
    if not text:
        raise HTTPException(400, detail="Texto vazio após limpeza")

    ref = (body.reference_id or os.getenv("FISH_VOICE_ID", "")).strip()
    fmt = (body.format or "mp3").strip() or "mp3"
    model_primary = os.getenv("FISH_TTS_MODEL", "s2.1-pro").strip() or "s2.1-pro"
    models_try = []
    for m in (model_primary, "s2.1-pro", "s2.1-pro-free", "s2-pro", "s1"):
        if m and m not in models_try:
            models_try.append(m)

    last_err = "Fish Audio sem resposta"

    async with httpx.AsyncClient(timeout=90.0) as client:
        for use_ref in (True, False):
            payload = {
                "text": text,
                "format": fmt,
                # Fish: balanced ≈ menor tempo até o 1º áudio
                "latency": "balanced",
                "chunk_length": 150,
                "normalize": True,
            }
            if use_ref and ref:
                payload["reference_id"] = ref
            elif use_ref and not ref:
                continue

            for model in models_try:
                try:
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
                    last_err = f"rede: {e}"
                    logger.exception("fish tts network")
                    continue

                if r.status_code < 400 and r.content and len(r.content) > 100:
                    media = "audio/mpeg" if fmt == "mp3" else "audio/wav"
                    return Response(content=r.content, media_type=media)

                snippet = (r.text or "")[:400]
                last_err = f"model={model} status={r.status_code} body={snippet}"
                logger.warning("fish tts fail %s", last_err)
                if r.status_code in (401, 403):
                    raise HTTPException(502, detail=f"Fish Auth ({r.status_code}): {snippet}")

    raise HTTPException(502, detail=f"Fish Audio: {last_err}")


@router.get("/tts/health")
async def tts_health():
    return {
        "fish_key_configured": bool(os.getenv("FISH_AUDIO_API_KEY", "").strip()),
        "fish_voice_configured": bool(os.getenv("FISH_VOICE_ID", "").strip()),
        "fish_model": os.getenv("FISH_TTS_MODEL", "s2.1-pro"),
    }
