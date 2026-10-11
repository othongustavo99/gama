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
from .security import body_too_large, rate_limit_chat, rate_limit_default, require_api_key

logger = logging.getLogger("gama")
VERSION = "0.13.0"


@asynccontextmanager
async def lifespan(_app: FastAPI):
    if settings.PROVIDER == "openrouter" and not settings.OPENROUTER_API_KEY:
        logger.warning("OPENROUTER_API_KEY ausente: /chat vai falhar até ser configurada.")
    if not settings.GAMA_API_KEY:
        logger.warning("GAMA_API_KEY ausente: a API está ABERTA para qualquer pessoa com a URL.")
    if settings.CORS_ORIGINS == ["*"]:
        logger.info("CORS aberto (*). Restrinja com CORS_ORIGINS se houver cliente web.")
    yield
    await llm.aclose()


app = FastAPI(title="Frequência40 API", version=VERSION, lifespan=lifespan)

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


_guard = [Depends(require_api_key), Depends(rate_limit_default)]
_chat_guard = [Depends(require_api_key), Depends(rate_limit_chat)]

app.include_router(chat_router, dependencies=_chat_guard)
app.include_router(memory_router, dependencies=_guard)
app.include_router(conversations_router, dependencies=_guard)
app.include_router(extract_router, dependencies=_guard)
app.include_router(search_router, dependencies=_chat_guard)
app.include_router(project_router, dependencies=_guard)
app.include_router(tts_router, dependencies=_chat_guard)
app.include_router(artifacts_router, dependencies=_guard)


@app.get("/health")
async def health():
    """Público e leve (healthcheck do Railway/Docker). O estado do LLM é cacheado."""
    ok = await llm.health()
    return {
        "status": "ok" if ok else "degraded",
        "service": "frequencia40",
        "version": VERSION,
        "provider": settings.PROVIDER,
        "web_search": settings.WEB_SEARCH_ENABLED,
        "agent_tools": settings.AGENT_TOOLS_ENABLED and settings.PROVIDER == "openrouter",
        "auth_required": bool(settings.GAMA_API_KEY),
        "llm": "online" if ok else "offline",
        "ollama": "online" if ok and settings.PROVIDER == "ollama" else ("n/a" if settings.PROVIDER != "ollama" else "offline"),
        "openrouter": "online" if ok and settings.PROVIDER == "openrouter" else ("n/a" if settings.PROVIDER != "openrouter" else "offline"),
        "features": [
            "chat", "memory", "memory_v2", "conversations", "rolling_summary", "extract",
            "multi_provider", "web_search", "agent_tools", "project_analyzer", "code_analyzer",
            "document_builder", "talk_skill", "image_analyzer", "image_gen", "tts",
        ],
    }
