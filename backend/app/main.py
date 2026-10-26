import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .config import settings
from .llm import llm
from .routes.chat import router as chat_router
from .routes.conversations import router as conversations_router
from .routes.extract import router as extract_router
from .routes.memory import router as memory_router
from .routes.search import router as search_router
from .routes.project import router as project_router
from .routes.tts import router as tts_router
from .routes.artifacts import router as artifacts_router
from .routes.media import router as media_router, public_router as media_public_router
from .security import body_too_large, rate_limit_chat, rate_limit_default, require_api_key
from .core.identity import require_auth, google_oauth_client_ids, current_user_id
from .storage_status import inspect_data_storage
from .core.production_guard import assert_safe_production_configuration

logger = logging.getLogger("gama")
VERSION = "0.13.0"


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Em modo comercial, falha antes de aceitar requisições se OAuth ou
    # configurações de segurança estiverem incompletas.
    assert_safe_production_configuration()
    storage = inspect_data_storage()
    if storage["status"] == "persistent":
        logger.info("Armazenamento persistente confirmado no volume Railway.")
    elif storage["status"] == "volume_not_attached":
        logger.error(
            "Railway Volume não detectado. Memória e conversas podem ser perdidas "
            "em um redeploy; conecte um volume ao serviço da API."
        )
    elif storage["status"] == "path_mismatch":
        logger.error(
            "DATA_DIR não corresponde ao mount do Railway Volume; "
            "verifique o mount path do serviço."
        )
    elif storage["status"] == "not_writable":
        logger.error("DATA_DIR não permite escrita; memória não poderá ser persistida.")
    else:
        logger.info("Armazenamento local ativo; volume persistente não verificado.")

    if settings.PROVIDER == "openrouter" and not settings.OPENROUTER_API_KEY:
        logger.warning("OPENROUTER_API_KEY ausente: /chat vai falhar até ser configurada.")
    if not settings.GAMA_API_KEY:
        logger.warning("GAMA_API_KEY ausente: a proteção por chave de API está desativada.")
    if not require_auth():
        logger.warning("GAMA_REQUIRE_AUTH está desativado: rotas legadas aceitam X-User-Id informado pelo cliente.")
    elif not google_oauth_client_ids():
        logger.error("GOOGLE_OAUTH_CLIENT_IDS ausente: autenticação Google recusará todas as sessões.")
    if settings.CORS_ORIGINS == ["*"]:
        logger.info("CORS aberto (*). Restrinja com CORS_ORIGINS se houver cliente web.")
    yield
    await llm.aclose()


app = FastAPI(title="Gama API", version=VERSION, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def limit_body(request: Request, call_next):
    limit = body_too_large(request)
    if limit:
        return JSONResponse({"detail": f"Corpo maior que {limit // (1024 * 1024)} MB"}, status_code=413)
    return await call_next(request)


# Todas as rotas não públicas também precisam de identidade autenticada,
# inclusive /models, /extract, /search e /tts, que antes dependiam somente da
# chave de app distribuída ao cliente (não sigilosa em um APK/EXE).
_guard = [Depends(require_api_key), Depends(rate_limit_default), Depends(current_user_id)]
_chat_guard = [Depends(require_api_key), Depends(rate_limit_chat), Depends(current_user_id)]

app.include_router(chat_router, dependencies=_chat_guard)
app.include_router(memory_router, dependencies=_guard)
app.include_router(conversations_router, dependencies=_guard)
app.include_router(extract_router, dependencies=_guard)
app.include_router(search_router, dependencies=_chat_guard)
app.include_router(project_router, dependencies=_guard)
app.include_router(tts_router, dependencies=_chat_guard)
app.include_router(artifacts_router, dependencies=_guard)
app.include_router(media_router, dependencies=_guard)
# Referências HMAC de curta duração precisam ser acessíveis ao provedor do modelo; o endpoint valida assinatura antes de servir o arquivo.
app.include_router(media_public_router)


@app.get("/health")
async def health():
    """Public liveness probe; avoid exposing provider, version, and feature flags."""
    return {"status": "ok"}
