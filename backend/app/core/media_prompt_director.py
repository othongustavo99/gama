"""Diretor opcional de prompt: aprimora briefings curtos, sem substituir o original."""
from __future__ import annotations
import logging
import httpx
from ..config import settings

logger = logging.getLogger(__name__)

async def refine_media_brief(prompt: str, *, kind: str, style: str = "") -> str:
    original = (prompt or "").strip()
    # Briefings extensos já são completos; não os resuma nem consuma créditos.
    if not original or len(original) > 320 or kind not in {"image", "video"}:
        return original
    if not getattr(settings, "GAMA_MEDIA_PROMPT_DIRECTOR_ENABLED", True):
        return original
    if settings.PROVIDER != "openrouter" or not settings.OPENROUTER_API_KEY:
        return original
    model = getattr(settings, "GAMA_MEDIA_PROMPT_DIRECTOR_MODEL", "").strip()
    if not model:
        return original
    system = (
        "Você é uma diretora criativa para geração de mídia. Reescreva em português "
        "o briefing em uma única descrição visual precisa (máximo 750 caracteres). "
        "Acrescente apenas detalhes neutros úteis de composição/ação, sem inventar "
        "pessoas ou texto, sem mudar o assunto ou impor iluminação realista. "
        "Respeite estilos noturno, neon, ilustração, minimalista e qualquer texto "
        "literal ou restrição. Não adicione prefácios, aspas ou instruções. "
    )
    try:
        async with httpx.AsyncClient(timeout=14.0) as client:
            response = await client.post(
                f"{settings.OPENROUTER_BASE_URL}/chat/completions",
                headers={
                    "Authorization": f"Bearer {settings.OPENROUTER_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model,
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": f"TIPO: {kind}; ESTILO: {style or 'livre'}; BRIEFING: {original}"},
                    ],
                    "max_tokens": 280,
                    "temperature": 0.3,
                },
            )
            response.raise_for_status()
            suggestion = str(((response.json().get("choices") or [{}])[0]
                .get("message") or {}).get("content") or "").strip().strip('"')
            if not suggestion or len(suggestion) > 850:
                return original
            # O texto original é sempre incluído, para o diretor não apagar
            # detalhes e garantir rastreabilidade do briefing.
            return f"Briefing original (prioritário): {original}\nDireção visual sugerida: {suggestion}"
    except Exception as exc:
        logger.warning("media prompt director fallback: %s", type(exc).__name__)
        return original
