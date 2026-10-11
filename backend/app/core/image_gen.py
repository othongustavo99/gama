"""Geração e edição de imagens via OpenRouter Image API — GPT Image 2.5 Sunburst."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from enum import Enum
from typing import Any, Optional

import httpx

from ..config import settings

logger = logging.getLogger(__name__)

DEFAULT_IMAGE_MODEL = "openai/gpt-image-2.5-sunburst"


class ImageIntent(str, Enum):
    GENERATE = "generate"   # criar imagem do zero (text-to-image)
    EDIT = "edit"           # editar/modificar imagem anexada
    IMPROVE = "improve"     # melhorar qualidade / upscale / enhance
    ANALYZE = "analyze"     # só analisar (não gerar)
    NONE = "none"           # sem intenção de imagem


@dataclass
class ImageRequest:
    intent: ImageIntent
    prompt: str
    confidence: float  # 0.0 a 1.0


# ── Regexes de intenção ──────────────────────────────────────────────────────

_GENERATE = re.compile(
    r"(?i)("
    r"\b(cria|crie|gere|gera|gerar|criar|desenhe|desenha|imagine|imagina|faz|faça|faz uma)\b"
    r".{0,50}\b(imagem|img|figura|ilustra\w*|foto|picture|image|arte|desenho)\b"
    r"|"
    r"\b(imagem|ilustra\w*|figura|foto|picture)\b.{0,25}\b(de|do|da|com|sobre|mostrando)\b"
    r"|"
    r"\b(generate|create|draw|imagine|make|paint)\b.{0,50}\b(image|picture|illustration|art|photo|drawing)\b"
    r"|"
    r"\b(text[\s-]?to[\s-]?image|txt2img|text2img)\b"
    r"|"
    r"\b(quero uma imagem|quero uma foto|quero uma ilustração|quero um desenho)\b"
    r")",
)

_EDIT = re.compile(
    r"(?i)("
    r"\b(edita|edite|editar|modifica|modifique|modificar|altera|altere|alterar|"
    r"muda|mude|mudar|troca|troque|trocar|remove|remova|remover|"
    r"adiciona|adicione|adicionar|coloca|coloque|colocar|"
    r"substitui|substitua|substituir|apaga|apague|apagar)\b"
    r".{0,40}\b(imagem|img|foto|picture|image|nessa|nessa imagem|dessa imagem|da imagem)\b"
    r"|"
    r"\b(nessa imagem|nessa foto|dessa imagem|da imagem|na imagem|na foto)\b"
    r".{0,40}\b(muda|mude|troca|troque|remove|remova|adiciona|adicione|coloca|coloque|"
    r"edita|edite|modifica|modifique|altera|altere|substitui)\b"
    r"|"
    r"\b(edit|modify|change|replace|remove|add|put)\b.{0,40}\b(image|photo|picture|this image)\b"
    r"|"
    r"\b(this image|the image|the photo)\b.{0,40}\b(edit|modify|change|replace|remove|add)\b"
    r"|"
    r"\b(image[\s-]?to[\s-]?image|img2img)\b"
    r")",
)

_IMPROVE = re.compile(
    r"(?i)("
    r"\b(melhora|melhore|melhorar|aprimora|aprimore|aprimorar|"
    r"aumenta a qualidade|aumente a qualidade|melhora a qualidade|"
    r"upscale|enhance|refina|refine|refinar|"
    r"deixa mais nítida|deixe mais nítida|mais nitidez|"
    r"melhora a resolução|aumenta a resolução|melhor resolução|"
    r"deixa melhor|deixe melhor|fica melhor)\b"
    r".{0,30}\b(imagem|img|foto|picture|image)?\b"
    r"|"
    r"\b(imagem|foto|picture|image)\b.{0,20}\b(melhor|mais nítida|com mais qualidade|em alta resolução)\b"
    r"|"
    r"\b(improve|enhance|upscale|sharpen|refine|make better|higher quality|higher resolution)\b"
    r".{0,30}\b(image|photo|picture)?\b"
    r")",
)

_ANALYZE = re.compile(
    r"(?i)\b("
    r"analise|analisa|analyze|descreva|descreve|describe|"
    r"o que (tem|há|aparece) (na|nessa|dessa) (imagem|foto)|"
    r"what('s| is) in (the|this) (image|photo)|"
    r"explique (a|essa|desta) (imagem|foto)|"
    r"me diga o que (tem|há) (na|nessa) (imagem|foto)"
    r")\b",
)

_WEAK_GENERATE = re.compile(
    r"(?i)\b(imagem de|foto de|ilustração de|desenho de|picture of|image of)\b",
)


def detect_image_intent(
    user_text: str,
    has_attached_images: bool = False,
) -> ImageRequest:
    """
    Detecta a intenção do usuário em relação a imagens.
    Retorna ImageRequest com intent, prompt limpo e confidence.
    """
    text = (user_text or "").strip()
    if len(text) < 4:
        return ImageRequest(intent=ImageIntent.NONE, prompt="", confidence=0.0)

    # 1. Análise pura (só se tiver imagem anexada e não pedir edição/geração)
    if has_attached_images and _ANALYZE.search(text):
        if not (_EDIT.search(text) or _IMPROVE.search(text) or _GENERATE.search(text)):
            return ImageRequest(
                intent=ImageIntent.ANALYZE,
                prompt=text,
                confidence=0.95,
            )

    # 2. Melhorar qualidade (prioridade alta se tiver imagem anexada)
    if _IMPROVE.search(text):
        conf = 0.92 if has_attached_images else 0.75
        return ImageRequest(
            intent=ImageIntent.IMPROVE,
            prompt=_clean_prompt(text, mode="improve"),
            confidence=conf,
        )

    # 3. Editar
    if _EDIT.search(text):
        conf = 0.90 if has_attached_images else 0.70
        return ImageRequest(
            intent=ImageIntent.EDIT,
            prompt=_clean_prompt(text, mode="edit"),
            confidence=conf,
        )

    # 4. Gerar do zero
    if _GENERATE.search(text):
        return ImageRequest(
            intent=ImageIntent.GENERATE,
            prompt=_clean_prompt(text, mode="generate"),
            confidence=0.88,
        )

    # 5. Sinal fraco + sem imagem anexada → provavelmente gerar
    if not has_attached_images and _WEAK_GENERATE.search(text):
        return ImageRequest(
            intent=ImageIntent.GENERATE,
            prompt=_clean_prompt(text, mode="generate"),
            confidence=0.65,
        )

    return ImageRequest(intent=ImageIntent.NONE, prompt="", confidence=0.0)


def wants_image_generation(user_text: str, has_attached_images: bool = False) -> bool:
    """Compatibilidade: True se for GENERATE, EDIT ou IMPROVE."""
    req = detect_image_intent(user_text, has_attached_images)
    return req.intent in (ImageIntent.GENERATE, ImageIntent.EDIT, ImageIntent.IMPROVE)


def build_image_prompt(user_text: str, intent: Optional[ImageIntent] = None) -> str:
    """Monta o prompt final conforme a intenção."""
    if intent is None:
        intent = detect_image_intent(user_text).intent

    cleaned = _clean_prompt(user_text, mode=intent.value if intent != ImageIntent.NONE else "generate")

    if intent == ImageIntent.IMPROVE:
        return (
            f"Improve and enhance this image: {cleaned}. "
            f"Higher resolution, sharper details, better lighting, natural colors, "
            f"professional quality, no artifacts."
        )

    if intent == ImageIntent.EDIT:
        return (
            f"{cleaned}. "
            f"Edit the provided image accordingly. Keep the original composition and style "
            f"unless the user asked to change them. High quality, coherent result."
        )

    # GENERATE (padrão)
    return (
        f"{cleaned}. High quality, detailed, coherent composition, "
        f"natural lighting, no text overlays unless requested."
    )


def _clean_prompt(text: str, mode: str = "generate") -> str:
    """Remove verbos de comando e deixa o prompt descritivo."""
    base = (text or "").strip()

    patterns = {
        "generate": (
            r"(?i)^(por\s+favor\s+)?"
            r"(cria|crie|gere|gera|gerar|criar|desenhe|desenha|imagine|imagina|"
            r"faz|faça|generate|create|draw|make|paint)\s+"
            r"((uma?|an?)\s+)?"
            r"(imagem|image|picture|illustration|foto|desenho|arte)?\s*"
            r"(de|do|da|of|with|showing)?\s*"
        ),
        "edit": (
            r"(?i)^(por\s+favor\s+)?"
            r"(edita|edite|editar|modifica|modifique|modificar|altera|altere|"
            r"muda|mude|troca|troque|remove|remova|adiciona|adicione|"
            r"edit|modify|change|replace|remove|add)\s+"
            r"((a|essa|desta|nessa|the|this)\s+)?"
            r"(imagem|image|foto|picture|photo)?\s*"
            r"(e\s+)?(para\s+)?"
        ),
        "improve": (
            r"(?i)^(por\s+favor\s+)?"
            r"(melhora|melhore|melhorar|aprimora|aprimore|upscale|enhance|"
            r"improve|refine)\s+"
            r"((a|essa|desta|nessa|the|this)\s+)?"
            r"(imagem|image|foto|picture|photo|qualidade|qualidade da imagem)?\s*"
        ),
    }

    pattern = patterns.get(mode, patterns["generate"])
    cleaned = re.sub(pattern, "", base).strip()

    cleaned = re.sub(
        r"(?i)^(a|uma|an|the)\s+(imagem|image|foto|picture)\s+(de|of|com|with)\s+",
        "",
        cleaned,
    ).strip()

    if len(cleaned) < 3:
        cleaned = base

    return cleaned


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
    items = data.get("data") or data.get("images") or []
    if isinstance(items, list) and items:
        item = items[0] if isinstance(items[0], dict) else {}
        b64 = item.get("b64_json") or item.get("b64") or item.get("base64")
        if not b64 and item.get("url") and str(item["url"]).startswith("data:"):
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