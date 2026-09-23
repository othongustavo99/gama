from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .ollama import ollama
from .routes.chat import router as chat_router


app = FastAPI(
    title="Frequência40 API",
    version="0.1.0",
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


app.include_router(
    chat_router,
)


@app.get("/health")
async def health():
    ollama_ok = await ollama.health()

    if not ollama_ok:
        return {
            "status": "degraded",
            "service": "frequencia40",
            "ollama": "offline",
        }

    return {
        "status": "ok",
        "service": "frequencia40",
        "ollama": "online",
    }