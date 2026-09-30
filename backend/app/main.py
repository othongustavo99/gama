from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .ollama import ollama
from .routes.chat import router as chat_router
from .routes.memory import router as memory_router
from .routes.extract import router as extract_router


app = FastAPI(
    title="Frequência40 API",
    version="0.4.0",
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
    ollama_ok = await ollama.health()
    features = [
        "chat",
        "memory",
        "context_summary",
        "model_summary",
        "memory_meta",
        "extract",
    ]

    return {
        "status": "ok" if ollama_ok else "degraded",
        "service": "frequencia40",
        "version": "0.4.0",
        "ollama": "online" if ollama_ok else "offline",
        "features": features,
    }
