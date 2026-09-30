import json

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ..core.gama import GamaCore
from ..llm import llm
from ..models import ChatRequest


router = APIRouter()
gama = GamaCore()


@router.get("/models")
async def list_models():
    models = await llm.list_models()
    return {
        "models": models,
        "provider": llm.provider,
    }


@router.post("/chat")
async def chat(request: ChatRequest):
    """
    Chat com Gama Core + busca na web (quando fizer sentido) + LLM.
    """
    messages = [
        {"role": message.role, "content": message.content}
        for message in request.messages
    ]

    model = llm.resolve_model(request.model)

    gama_messages, fact_saved, search_query = await gama.build_messages(
        messages,
        model=model,
        ollama_client=llm,
    )

    async def stream_with_meta():
        meta: dict = {}
        if fact_saved:
            meta["memory_saved"] = fact_saved
        if search_query:
            meta["web_search"] = search_query
        if meta:
            yield json.dumps({"gama_meta": meta}, ensure_ascii=False) + "\n"

        try:
            async for chunk in llm.stream_chat(
                model=model,
                messages=gama_messages,
            ):
                yield chunk
        except Exception as e:
            err = {
                "error": str(e),
                "message": {
                    "role": "assistant",
                    "content": f"Erro no provider: {e}",
                },
                "done": True,
            }
            yield json.dumps(err, ensure_ascii=False) + "\n"

    return StreamingResponse(
        stream_with_meta(),
        media_type="application/x-ndjson",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )

