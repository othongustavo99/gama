from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .llm import llm
from .routes.chat import router as chat_router
from .routes.extract import router as extract_router
from .routes.memory import router as memory_router


app = FastAPI(
    title="Frequência40 API",
    version="0.5.0",
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
    ]

    return {
        "status": "ok" if ok else "degraded",
        "service": "frequencia40",
        "version": "0.5.0",
        "provider": settings.PROVIDER,
        "llm": "online" if ok else "offline",
        # compat com app antigo que olha "ollama"
        "ollama": "online" if ok else "offline",
        "features": features,
    }
