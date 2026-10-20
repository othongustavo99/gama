"""Segurança da API: chave do app, limites por usuário/IP e limite de corpo.

Contexto: o backend era 100% aberto e a URL de produção está no repositório
público. Qualquer pessoa podia gastar o crédito do OpenRouter via /chat e ler ou
apagar a memória de outro usuário mandando `X-User-Id`.

Esta camada:
- exige `X-API-Key` (ou `Authorization: Bearer`) quando GAMA_API_KEY está definida;
- limita usuários autenticados individualmente e mantém IP como fallback;
- recusa corpos gigantes antes de ler.

Importante: a chave embutida no app pode ser extraída do APK. A autenticação
real usa um ID token Google validado no servidor e limites por identidade.
"""

from __future__ import annotations

import hmac
import logging
import time
from collections import defaultdict, deque
from typing import Callable, Deque, Dict, Optional

from fastapi import HTTPException, Request

from .config import settings
from .core.identity import _verified_user, require_auth

logger = logging.getLogger(__name__)


class SlidingWindowLimiter:
    def __init__(self, limit: int, window: float = 60.0, clock: Callable[[], float] = time.monotonic):
        self.limit, self.window, self.clock = limit, window, clock
        self.hits: Dict[str, Deque[float]] = defaultdict(deque)
        self._ops = 0

    def allow(self, key: str) -> bool:
        if self.limit <= 0:
            return True
        now = self.clock()
        q = self.hits[key]
        while q and now - q[0] > self.window:
            q.popleft()
        self._ops += 1
        if self._ops % 500 == 0:  # limpeza de chaves ociosas
            for k in [k for k, v in self.hits.items() if not v or now - v[-1] > self.window]:
                self.hits.pop(k, None)
            q = self.hits[key]
        if len(q) >= self.limit:
            return False
        q.append(now)
        return True

    def retry_after(self, key: str) -> int:
        q = self.hits.get(key)
        if not q:
            return 1
        return max(1, int(self.window - (self.clock() - q[0])) + 1)


def client_ip(request: Request) -> str:
    hops = settings.TRUSTED_PROXY_HOPS
    xff = request.headers.get("x-forwarded-for", "")
    if hops and xff:
        parts = [p.strip() for p in xff.split(",") if p.strip()]
        if len(parts) >= hops:
            return parts[-hops]  # o proxy confiável acrescenta o IP real no fim
    return request.client.host if request.client else "unknown"


_warned = False


async def require_api_key(request: Request) -> None:
    global _warned
    expected = settings.GAMA_API_KEY
    if not expected:
        if settings.REQUIRE_API_KEY:
            raise HTTPException(503, "Servidor sem GAMA_API_KEY configurada.")
        if not _warned:
            logger.warning("GAMA_API_KEY não definida: API ABERTA. Defina em produção.")
            _warned = True
        return
    given = request.headers.get("x-api-key", "")
    if not given:
        auth = request.headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            given = auth[7:].strip()
    if not hmac.compare_digest(given.encode(), expected.encode()):
        raise HTTPException(401, "Chave de API ausente ou inválida.")


def _make_limit_dep(limiter: SlidingWindowLimiter):
    async def dep(request: Request) -> None:
        key = client_ip(request)
        authorization = request.headers.get("authorization", "")
        if authorization.lower().startswith("bearer "):
            token = authorization[7:].strip()
            if token:
                try:
                    # Validated identity avoids charging unrelated users behind carrier NAT.
                    key = "user:" + await _verified_user(token)
                except Exception:
                    # The route's current_user_id dependency returns the real auth error.
                    pass
        elif not require_auth():
            # In legacy local mode, preserve separate limits for supplied accounts.
            legacy_id = (request.headers.get("x-user-id") or "").strip()
            if legacy_id:
                key = "legacy:" + legacy_id[:128]
        if not limiter.allow(key):
            raise HTTPException(429, "Muitas requisições. Aguarde um instante.",
                                headers={"Retry-After": str(limiter.retry_after(key))})
    return dep


chat_limiter = SlidingWindowLimiter(settings.RATE_LIMIT_CHAT_PER_MIN)
default_limiter = SlidingWindowLimiter(settings.RATE_LIMIT_DEFAULT_PER_MIN)
rate_limit_chat = _make_limit_dep(chat_limiter)
rate_limit_default = _make_limit_dep(default_limiter)


def body_too_large(request: Request) -> Optional[int]:
    """Retorna o limite em bytes se Content-Length excedê-lo."""
    limit = settings.MAX_BODY_MB * 1024 * 1024
    try:
        if int(request.headers.get("content-length") or 0) > limit:
            return limit
    except ValueError:
        pass
    return None
