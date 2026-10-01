import json
import logging

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ..core.gama import GamaCore
from ..llm import llm, LLMClient
from ..models import ChatRequest
from ..web_search import should_search, search_web

logger = logging.getLogger(__name__)
router = APIRouter()
gama = GamaCore()


@router.get("/models")
async def list_models():
    models = await llm.list_models()
    return {"models": models, "provider": llm.provider}


@router.post("/chat")
async def chat(request: ChatRequest):
    """
    Stream com fases:
      1) gama_meta.phase = searching  (se for buscar)
      2) gama_meta.phase = thinking + sources
      3) tokens da resposta
    """
    messages = [
        {"role": m.role, "content": m.content} for m in request.messages
    ]
    model = llm.resolve_model(request.model)

    last_user = ""
    if messages and messages[-1].get("role") == "user":
        last_user = messages[-1].get("content") or ""

    will_search = bool(last_user and should_search(last_user))

    async def stream_with_meta():
        sources: list = []
        search_query = None
        fact_saved = None
        gama_messages = None

        try:
            # --- fase: buscando ---
            if will_search:
                search_query = last_user.strip()[:200]
                yield json.dumps(
                    {
                        "gama_meta": {
                            "phase": "searching",
                            "web_search": search_query,
                        }
                    },
                    ensure_ascii=False,
                ) + "\n"

                try:
                    sources = await search_web(search_query, max_results=8)
                except Exception as e:
                    logger.warning("search failed: %s", e)
                    sources = []

                yield json.dumps(
                    {
                        "gama_meta": {
                            "phase": "thinking",
                            "web_search": search_query,
                            "sources": sources,
                        }
                    },
                    ensure_ascii=False,
                ) + "\n"
            else:
                yield json.dumps(
                    {"gama_meta": {"phase": "thinking"}},
                    ensure_ascii=False,
                ) + "\n"

            # --- monta contexto ---
            try:
                gama_messages, fact_saved, search_query, sources = await gama.build_messages(
                    messages,
                    model=model,
                    ollama_client=llm,
                    prefetched_sources=sources if will_search else None,
                    prefetched_query=search_query,
                )
            except Exception as e:
                logger.exception("build_messages: %s", e)
                gama_messages = [
                    {
                        "role": "system",
                        "content": "Você é Gamma. Responda à última mensagem do usuário.",
                    },
                    *messages[-12:],
                ]

            if fact_saved:
                yield json.dumps(
                    {"gama_meta": {"memory_saved": fact_saved}},
                    ensure_ascii=False,
                ) + "\n"

            if sources and not will_search:
                yield json.dumps(
                    {
                        "gama_meta": {
                            "phase": "thinking",
                            "sources": sources,
                            "web_search": search_query,
                        }
                    },
                    ensure_ascii=False,
                ) + "\n"

            # --- tokens ---
            yield json.dumps(
                {"gama_meta": {"phase": "typing"}},
                ensure_ascii=False,
            ) + "\n"

            img_payload = None
            if getattr(request, "images", None):
                img_payload = [
                    {"mime": i.mime, "data": i.data, "name": i.name}
                    for i in request.images
                    if i.data
                ]

            # Troca automática para modelo de visão só quando há imagem
            active_model = model
            if img_payload:
                from ..config import settings as _settings
                if llm.provider == "ollama":
                    active_model = (
                        getattr(_settings, "VISION_MODEL", None)
                        or "qwen2-vl"
                    )
                elif llm.provider == "openrouter":
                    active_model = (
                        getattr(_settings, "VISION_MODEL", None)
                        or "openai/gpt-4o-mini"
                    )
                elif llm.provider == "groq":
                    # Groq: modelo com suporte a visão se disponível
                    active_model = (
                        getattr(_settings, "VISION_MODEL", None)
                        or model
                    )
                gama_messages = LLMClient.inject_images(
                    gama_messages,
                    img_payload,
                    provider=llm.provider,
                )
                yield json.dumps(
                    {
                        "gama_meta": {
                            "phase": "thinking",
                            "vision_model": active_model,
                        }
                    },
                    ensure_ascii=False,
                ) + "\n"

            async for chunk in llm.stream_chat(
                model=active_model,
                messages=gama_messages,
            ):
                yield chunk

        except Exception as e:
            logger.exception("chat stream: %s", e)
            yield json.dumps(
                {
                    "error": str(e),
                    "message": {
                        "role": "assistant",
                        "content": f"Não consegui completar a resposta ({e}).",
                    },
                    "done": True,
                },
                ensure_ascii=False,
            ) + "\n"

    return StreamingResponse(
        stream_with_meta(),
        media_type="application/x-ndjson",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
