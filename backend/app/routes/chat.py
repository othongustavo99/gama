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

    return {
        "models": models,
    }


@router.post("/chat")
async def chat(request: ChatRequest):
    """
    Recebe a conversa do Flutter.

    O Gama Core adiciona:
    - personalidade
    - system prompt
    - contexto

    Depois a conversa preparada é enviada ao Ollama.
    """

    messages = [
        {
            "role": message.role,
            "content": message.content,
        }
        for message in request.messages
    ]

    gama_messages = gama.build_messages(messages)

    return StreamingResponse(
        ollama.stream_chat(
            model=request.model,
            messages=gama_messages,
        ),
        media_type="application/x-ndjson",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )