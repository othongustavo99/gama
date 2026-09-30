import json

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ..core.gama import GamaCore
from ..models import ChatRequest
from ..ollama import OllamaClient


router = APIRouter()

ollama = OllamaClient()
gama = GamaCore()


@router.get("/models")
async def list_models():
    models = await ollama.list_models()
    return {"models": models}


@router.post("/chat")
async def chat(request: ChatRequest):
    """
    Chat com:
    - personalidade + memória
    - resumo de contexto pelo modelo (quando a conversa é longa)
    - meta NDJSON inicial se um fato foi gravado na memória
    """
    messages = [
        {"role": message.role, "content": message.content}
        for message in request.messages
    ]

    gama_messages, fact_saved = await gama.build_messages(
        messages,
        model=request.model,
        ollama_client=ollama,
    )

    async def stream_with_meta():
        # Linha de meta (Flutter trata e não mostra como texto da resposta)
        if fact_saved:
            meta = {
                "gama_meta": {
                    "memory_saved": fact_saved,
                }
            }
            yield json.dumps(meta, ensure_ascii=False) + "\n"

        async for chunk in ollama.stream_chat(
            model=request.model,
            messages=gama_messages,
        ):
            yield chunk

    return StreamingResponse(
        stream_with_meta(),
        media_type="application/x-ndjson",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
