import json
import logging

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ..core.gama import GamaCore
from ..llm import llm
from ..models import ChatRequest

logger = logging.getLogger(__name__)
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
    Chat + busca (nunca deve cair em 502 por falha de search).
    """
    messages = [
        {"role": message.role, "content": message.content}
        for message in request.messages
    ]

    model = llm.resolve_model(request.model)

    fact_saved = None
    search_query = None
    try:
        gama_messages, fact_saved, search_query = await gama.build_messages(
            messages,
            model=model,
            ollama_client=llm,
        )
    except Exception as e:
        logger.exception("build_messages failed: %s", e)
        # Fallback: manda só as mensagens do usuário + system mínimo
        gama_messages = [
            {
                "role": "system",
                "content": (
                    "Você é Gamma. Houve um problema interno ao montar o contexto. "
                    "Responda o melhor possível à última mensagem do usuário."
                ),
            },
            *messages[-12:],
        ]

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
            logger.exception("stream_chat failed: %s", e)
            err = {
                "error": str(e),
                "message": {
                    "role": "assistant",
                    "content": (
                        "Não consegui completar a resposta agora "
                        f"(erro no modelo/API: {e}). Tente de novo em instantes."
                    ),
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
