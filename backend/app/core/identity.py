"""Identidade do usuário para rotas que guardam dados por usuário.

Ordem de decisão (`current_user_id`):
  1. `Authorization: Bearer <access_token do Google>` → verificado no Google
     (userinfo). O user_id vira `google_<id>`, o mesmo formato que o app já usa.
     Token inválido → 401 (nunca cai para o cabeçalho).
  2. Sem token: se GAMA_REQUIRE_AUTH=1 → 401.
  3. Sem token e sem GAMA_REQUIRE_AUTH: usa `X-User-Id` (modo legado, compatível
     com o app atual). Valor inválido → 400. Ausente → "default".

Rollout recomendado: publicar o servidor, publicar o app que envia o Bearer,
e só então definir GAMA_REQUIRE_AUTH=1 no Railway.
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


async def verify_google_access_token(token: str) -> str:
    """Consulta o Google e devolve `google_<id>`. Levanta PermissionError se inválido."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        r = await client.get(GOOGLE_USERINFO_URL, headers={"Authorization": f"Bearer {token}"})
    if r.status_code != 200:
        raise PermissionError("token Google inválido ou expirado")
    gid = str((r.json() or {}).get("id") or "").strip()
    if not gid:
        raise PermissionError("perfil Google sem id")
    return f"google_{gid}"


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
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
        if token:
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
