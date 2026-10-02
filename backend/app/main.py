from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .llm import llm
from .routes.chat import router as chat_router
from .routes.extract import router as extract_router
from .routes.memory import router as memory_router
from .routes.search import router as search_router


app = FastAPI(
    title="Frequência40 API",
    version="0.7.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(chat_router)
app.include_router(memory_router)
app.include_router(extract_router)
app.include_router(search_router)


@app.get("/health")
async def health():
    ok = await llm.health()
    features = [
        "chat",
        "memory",
        "context_summary",
        "model_summary",
        "memory_meta",
        "extract",
        "multi_provider",
        "web_search",
    ]

    return {
        "status": "ok" if ok else "degraded",
        "service": "frequencia40",
        "version": "0.7.0",
        "provider": settings.PROVIDER,
        "web_search": settings.WEB_SEARCH_ENABLED,
        "llm": "online" if ok else "offline",
        "ollama": "online" if ok and settings.PROVIDER == "ollama" else ("n/a" if settings.PROVIDER != "ollama" else "offline"),
        "groq": "online" if ok and settings.PROVIDER == "groq" else ("n/a" if settings.PROVIDER != "groq" else "offline"),
        "features": features,
    }
