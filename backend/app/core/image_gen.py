"""Geração de imagens via OpenRouter Image API — GPT Image 2.5 Sunburst."""

from __future__ import annotations

import logging
import re
from typing import Any, Optional

import httpx

from ..config import settings

logger = logging.getLogger(__name__)

# Modelo pedido pelo produto
DEFAULT_IMAGE_MODEL = "openai/gpt-image-2.5-sunburst"

# Intenção explícita de criar/imaginar imagem (pt/en)
_IMAGE_INTENT = re.compile(
    r"(?i)("
    r"\b(cria|crie|gere|gera|gerar|criar|desenhe|desenha|imagine|imagina)\b.{0,40}\b(imagem|img|figura|ilustra\w*|foto|picture|image)\b"
    r"|"
    r"\b(imagem|ilustra\w*|figura)\b.{0,20}\b(de|do|da|com|sobre)\b"
    r"|"
    r"\b(generate|create|draw|imagine|make)\b.{0,40}\b(image|picture|illustration|art)\b"
    r"|"
    r"\b(text[\s-]?to[\s-]?image|txt2img)\b"
    r")",
)

# Evita falso positivo em análise de imagem anexada
_ANALYZE_ONLY = re.compile(
    r"(?i)\b(analise|analisa|analyze|descreva|descreve|o que (tem|há) na imagem|what('s| is) in the (image|photo))\b",
)


def wants_image_generation(user_text: str, has_attached_images: bool = False) -> bool:
    text = (user_text or "").strip()
    if len(text) < 6:
        return False
    if has_attached_images and _ANALYZE_ONLY.search(text) and not _IMAGE_INTENT.search(text):
        return False
    return bool(_IMAGE_INTENT.search(text))


def build_image_prompt(user_text: str) -> str:
    """Usa o pedido do usuário como prompt; reforça qualidade visual."""
    base = (user_text or "").strip()
    # Remove verbos de comando genéricos no início para o prompt ficar descritivo
    cleaned = re.sub(
        r"(?i)^(por\s+favor\s+)?(cria|crie|gere|gera|gerar|criar|desenhe|desenha|imagine|imagina|generate|create|draw|make)\s+"
        r"((uma?|an?)\s+)?(imagem|image|picture|illustration|foto)?\s*(de|do|da|of|with)?\s*",
        "",
        base,
    ).strip()
    if len(cleaned) < 4:
        cleaned = base
    return (
        f"{cleaned}. High quality, detailed, coherent composition, "
        f"natural lighting, no text overlays unless requested."
    )


async def generate_image(
    prompt: str,
    *,
    model: Optional[str] = None,
    aspect_ratio: str = "1:1",
    timeout: float = 120.0,
) -> dict[str, Any]:
    """
    Chama OpenRouter POST /api/v1/images
    Retorno: { ok, mime, base64, model, error? }
    """
    if settings.PROVIDER != "openrouter":
        return {
            "ok": False,
            "error": "Geração de imagem requer LLM_PROVIDER=openrouter",
        }
    if not settings.OPENROUTER_API_KEY:
        return {"ok": False, "error": "OPENROUTER_API_KEY não configurada"}

    model_id = (model or getattr(settings, "IMAGE_GEN_MODEL", None) or DEFAULT_IMAGE_MODEL).strip()
    url = f"{settings.OPENROUTER_BASE_URL}/images"
    # Alguns deployments usam /images/generations — tentamos o endpoint unificado
    headers = {
        "Authorization": f"Bearer {settings.OPENROUTER_API_KEY}",
        "Content-Type": "application/json",
        "HTTP-Referer": settings.OPENROUTER_HTTP_REFERER or settings.APP_URL or "https://gama.app",
        "X-Title": settings.OPENROUTER_APP_TITLE or "Frequencia40-Gamma",
    }
    payload = {
        "model": model_id,
        "prompt": prompt[:4000],
        "aspect_ratio": aspect_ratio,
    }

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(url, headers=headers, json=payload)
            if r.status_code == 404:
                # fallback OpenAI-style
                r = await client.post(
                    f"{settings.OPENROUTER_BASE_URL}/images/generations",
                    headers=headers,
                    json={
                        "model": model_id,
                        "prompt": prompt[:4000],
                        "n": 1,
                        "size": "1024x1024",
                    },
                )
            if not r.is_success:
                logger.warning("image gen fail %s: %s", r.status_code, r.text[:400])
                return {
                    "ok": False,
                    "error": f"OpenRouter imagem HTTP {r.status_code}: {r.text[:240]}",
                    "model": model_id,
                }
            data = r.json()
    except Exception as e:
        logger.exception("image gen network")
        return {"ok": False, "error": str(e), "model": model_id}

    b64 = None
    mime = "image/png"
    # Formatos possíveis: data[].b64_json | data[].url | images[]
    items = data.get("data") or data.get("images") or []
    if isinstance(items, list) and items:
        item = items[0] if isinstance(items[0], dict) else {}
        b64 = item.get("b64_json") or item.get("b64") or item.get("base64")
        if not b64 and item.get("url") and str(item["url"]).startswith("data:"):
            # data:image/png;base64,....
            m = re.match(r"data:([^;]+);base64,(.+)", str(item["url"]), re.S)
            if m:
                mime = m.group(1)
                b64 = m.group(2)
        if item.get("mime"):
            mime = str(item["mime"])
    if not b64 and isinstance(data.get("b64_json"), str):
        b64 = data["b64_json"]

    if not b64:
        return {
            "ok": False,
            "error": "Resposta sem imagem em base64",
            "model": model_id,
            "raw_keys": list(data.keys()) if isinstance(data, dict) else [],
        }

    return {
        "ok": True,
        "mime": mime,
        "base64": b64,
        "model": model_id,
        "prompt": prompt[:500],
    }
