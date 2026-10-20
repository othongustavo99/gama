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

# Reutiliza conexões HTTPS com o Fish Audio entre chamadas de TTS.
# Isso evita o custo de abrir uma nova conexão para cada frase.
_fish_client = httpx.AsyncClient(
    timeout=httpx.Timeout(90.0, connect=10.0),
)


class TtsIn(BaseModel):
    text: str = Field(min_length=1, max_length=4000)
    format: str = "mp3"
    reference_id: Optional[str] = None


def _clean_text(text: str) -> str:
    """Prepara texto para voz: sem código, tabelas, URLs ou abreviações ruins."""
    t = text.strip()

    # Código Markdown não deve ser narrado.
    t = re.sub(r"```[\s\S]*?```", " ", t)
    t = re.sub(r"`[^`]+`", " ", t)

    # Tabelas Markdown são visuais e não têm leitura natural.
    lines = []
    for line in re.split(r"\r?\n", t):
        stripped = line.strip()
        if "|" in stripped:
            continue
        if re.fullmatch(r"[-:|\s]+", stripped or "") and "-" in stripped:
            continue
        lines.append(line)
    t = " ".join(lines)

    # Markdown residual.
    t = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)
    t = re.sub(r"^\s{0,3}#{1,6}\s*", "", t, flags=re.MULTILINE)
    t = re.sub(r"(^|\s)[>*]+\s*", r"\1", t)
    t = re.sub(r"(^|\s)[-•]\s+", r"\1", t)
    t = re.sub(r"[*_~]+", " ", t)

    # URLs não são uma fala natural.
    t = re.sub(r"https?://\S+", " ", t)
    t = re.sub(r"www\.\S+", " ", t)

    # Abreviações frequentes.
    replacements = [
        (r"\bp\.\s*ex\.(?=\s|$)", "por exemplo"),
        (r"\bex\.(?=\s|$)", "por exemplo"),
        (r"\betc\.(?=\s|$)", "e assim por diante"),
        (r"\bobs\.(?=\s|$)", "observação"),
        (r"\baprox\.(?=\s|$)", "aproximadamente"),
        (r"\bvs\.(?=\s|$)", "versus"),
        (r"\bqdo\.(?=\s|$)", "quando"),
        (r"\bmsg\.(?=\s|$)", "mensagem"),
        (r"\bconfig\.(?=\s|$)", "configuração"),
        (r"\binfo\.(?=\s|$)", "informação"),
    ]
    for pattern, replacement in replacements:
        t = re.sub(pattern, replacement, t, flags=re.IGNORECASE)

    def expand_unit(match: re.Match[str]) -> str:
        number = match.group(1)
        unit = match.group(2).lower()
        try:
            value = float(number.replace(",", "."))
            singular = value == 1
        except ValueError:
            singular = False
        if unit in {"ms", "msec", "msecs"}:
            return f"{number} {'milissegundo' if singular else 'milissegundos'}"
        if unit in {"s", "seg", "segs"}:
            return f"{number} {'segundo' if singular else 'segundos'}"
        if unit in {"min", "mins", "m"}:
            return f"{number} {'minuto' if singular else 'minutos'}"
        return f"{number} {'hora' if singular else 'horas'}"

    t = re.sub(
        r"(?<!\w)(\d+(?:[.,]\d+)?)\s*(ms|msec|msecs|s|seg|segs|min|mins|m|h|hr|hrs)(?!\w)",
        expand_unit,
        t,
        flags=re.IGNORECASE,
    )

    t = t.replace("&", " e ")
    t = re.sub(r"\s*[|{}\[\]<>]+\s*", " ", t)
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

    client = _fish_client
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
