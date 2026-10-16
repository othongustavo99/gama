"""URLs temporárias assinadas para o provedor de vídeo buscar referências privadas."""
from __future__ import annotations

import hashlib
import hmac
import time
from urllib.parse import urlencode

from ..config import settings


def _secret() -> bytes:
    # Não gera links públicos se o backend não tiver um segredo configurado.
    value = (getattr(settings, "GAMA_API_KEY", "") or getattr(settings, "OPENROUTER_API_KEY", "")).strip()
    if len(value) < 24:
        raise RuntimeError("Configure GAMA_API_KEY (ou uma chave OpenRouter longa) para habilitar referências seguras de mídia.")
    return value.encode("utf-8")


def signature_for(artifact_id: str, expires: int, owner: str) -> str:
    msg = f"{artifact_id}.{expires}.{owner}".encode("utf-8")
    return hmac.new(_secret(), msg, hashlib.sha256).hexdigest()


def create_media_reference_url(artifact_id: str, owner: str, *, ttl_seconds: int = 1800) -> str:
    base = (getattr(settings, "APP_URL", "") or "").strip().rstrip("/")
    if not base.startswith("https://"):
        raise RuntimeError("Configure APP_URL com a URL HTTPS pública do backend para usar vídeo como referência de edição.")
    expires = int(time.time()) + max(60, min(ttl_seconds, 3600))
    query = urlencode({"expires": expires, "signature": signature_for(artifact_id, expires, owner)})
    return f"{base}/media/reference/{artifact_id}?{query}"


def validate_media_reference(artifact_id: str, expires: int, signature: str, owner: str) -> bool:
    import time as _time
    if expires < int(_time.time()) or expires > int(_time.time()) + 3600:
        return False
    try:
        expected = signature_for(artifact_id, expires, owner)
    except RuntimeError:
        return False
    return hmac.compare_digest(expected, signature or "")
