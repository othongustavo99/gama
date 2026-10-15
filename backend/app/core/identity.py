"""Identidade do usuário para rotas que guardam dados por usuário.

Identidade canônica para todas as rotas com dados de usuário.

Com token Google válido, o backend deriva o user_id de e-mail verificado usando
exatamente a normalização do app Flutter (`google_email_<email-normalizado>`).
Isso preserva as memórias gravadas anteriormente por X-User-Id e unifica o
escopo usado por chat, memória, projetos e artefatos. Token inválido nunca cai
para o cabeçalho. O modo legado por X-User-Id só deve ser usado localmente.
"""

from __future__ import annotations

import hashlib
import logging
import os
import re
import time
from typing import Awaitable, Callable, Optional

import httpx
from fastapi import Header, HTTPException

logger = logging.getLogger(__name__)

GOOGLE_USERINFO_URL = "https://www.googleapis.com/oauth2/v2/userinfo"
# IDs de conta podem incluir e-mail normalizado pelo app (google_email_nome@dominio).
# O valor continua limitado a caracteres seguros e não é usado como caminho de arquivo.
USER_ID_RE = re.compile(r"^[A-Za-z0-9_.@\-]{1,128}$")
_TOKEN_TTL_SEC = 300
_token_cache: dict[str, tuple[float, str]] = {}
_warned_legacy = False


def require_auth() -> bool:
    return os.getenv("GAMA_REQUIRE_AUTH", "").strip().lower() in {"1", "true", "yes", "on"}


def canonical_google_user_id(*, google_id: str, email: str | None) -> str:
    """Retorna o mesmo identificador que IdentityService.stableGoogleUserId."""
    normalized_email = (email or "").strip().lower()
    if "@" in normalized_email and len(normalized_email) >= 5:
        # Mantém compatibilidade com memórias/conversas antigas criadas pelo app.
        safe = re.sub(r"[^A-Za-z0-9_.@-]+", "_", normalized_email)
        candidate = f"google_email_{safe}"
        if len(candidate) <= 120:
            return candidate
    gid = (google_id or "").strip()
    if not gid:
        raise PermissionError("perfil Google sem identificador válido")
    return f"google_{gid}"


async def verify_google_access_token(token: str) -> str:
    """Valida o token no Google e retorna uma identidade canônica estável."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        r = await client.get(GOOGLE_USERINFO_URL, headers={"Authorization": f"Bearer {token}"})
    if r.status_code != 200:
        raise PermissionError("token Google inválido ou expirado")
    payload = r.json() or {}
    gid = str(payload.get("id") or "").strip()
    email = str(payload.get("email") or "").strip()
    # Se o provedor indicar explicitamente que o e-mail não é verificado,
    # não podemos usar esse endereço como namespace de dados.
    if payload.get("verified_email") is False:
        raise PermissionError("e-mail da conta Google não verificado")
    if not gid:
        raise PermissionError("perfil Google sem id")
    return canonical_google_user_id(google_id=gid, email=email)


async def verify_google_legacy_user_id(token: str) -> str:
    """Retorna google_<id> após revalidar o token; usado em migração legada restrita."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            GOOGLE_USERINFO_URL,
            headers={"Authorization": f"Bearer {token}"},
        )
    if response.status_code != 200:
        raise PermissionError("token Google inválido ou expirado")
    payload = response.json() or {}
    google_id = str(payload.get("id") or "").strip()
    if not google_id or payload.get("verified_email") is False:
        raise PermissionError("perfil Google inválido para migração")
    return f"google_{google_id}"


# Permite trocar o verificador em testes (sem rede).
_verifier: Callable[[str], Awaitable[str]] = verify_google_access_token


async def _verified_user(token: str) -> str:
    key = hashlib.sha256(token.encode("utf-8")).hexdigest()
    now = time.monotonic()
    hit = _token_cache.get(key)
    if hit and hit[0] > now:
        return hit[1]
    user_id = await _verifier(token)
    _token_cache[key] = (now + _TOKEN_TTL_SEC, user_id)
    if len(_token_cache) > 5000:  # evita crescimento sem limite
        for k in [k for k, (exp, _) in _token_cache.items() if exp <= now]:
            _token_cache.pop(k, None)
    return user_id


async def current_user_id(
    authorization: Optional[str] = Header(default=None),
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
) -> str:
    global _warned_legacy
    if authorization is not None:
        if not authorization.lower().startswith("bearer "):
            if require_auth():
                raise HTTPException(401, "Use Authorization: Bearer <token Google>")
        else:
            token = authorization[7:].strip()
            if not token:
                raise HTTPException(401, "Token de autenticação vazio")
            try:
                return await _verified_user(token)
            except PermissionError as exc:
                raise HTTPException(401, str(exc)) from exc
            except httpx.HTTPError as exc:
                logger.warning("falha ao consultar Google: %s", exc)
                raise HTTPException(503, "Não foi possível validar a sessão agora") from exc

    if require_auth():
        raise HTTPException(401, "Autenticação obrigatória")

    if not _warned_legacy:
        _warned_legacy = True
        logger.warning("identidade por X-User-Id (modo legado); defina GAMA_REQUIRE_AUTH=1 após o rollout do app")
    uid = (x_user_id or "default").strip() or "default"
    if not USER_ID_RE.fullmatch(uid):
        raise HTTPException(400, "X-User-Id inválido")
    return uid
