import json
import logging

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ..core.gama import GamaCore
from ..llm import llm, LLMClient
from ..models import ChatRequest
from ..web_search import should_search, search_web
from ..core.memory import get_store, extract_facts_with_llm

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
        _c = messages[-1].get("content") or ""
        if isinstance(_c, list):
            last_user = " ".join(
                (p.get("text") or "") for p in _c if isinstance(p, dict)
            )
        else:
            last_user = str(_c)

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
                uid = (request.user_id or "default").strip() or "default"
                gama_messages, fact_saved, search_query, sources = await gama.build_messages(
                    messages,
                    model=model,
                    ollama_client=llm,
                    prefetched_sources=sources if will_search else None,
                    prefetched_query=search_query,
                    user_id=uid,
                    auto_memory=getattr(request, "auto_memory", True),
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

            assistant_acc: list[str] = []
            async for chunk in llm.stream_chat(
                model=active_model,
                messages=gama_messages,
            ):
                try:
                    line = chunk.strip()
                    if line:
                        obj = json.loads(line)
                        c = ((obj.get("message") or {}).get("content")) or ""
                        if c:
                            assistant_acc.append(c)
                except Exception:
                    pass
                yield chunk

            # Memória automática pós-turno
            if getattr(request, "auto_memory", True):
                try:
                    u = (getattr(request, "user_id", None) or "default")
                    user_txt = last_user if isinstance(last_user, str) else ""
                    if user_txt.strip():
                        store = get_store(u)
                        existing = [f.get("text", "") for f in store.list_facts()]
                        new_facts = await extract_facts_with_llm(
                            user_text=user_txt,
                            assistant_text="".join(assistant_acc),
                            model=model,
                            llm_client=llm,
                            existing_facts=existing,
                        )
                        saved = store.add_facts(new_facts, source="auto")
                        if saved:
                            yield json.dumps(
                                {
                                    "gama_meta": {
                                        "memory_saved": saved[0]["text"],
                                        "memory_auto_count": len(saved),
                                    }
                                },
                                ensure_ascii=False,
                            ) + ""
                except Exception as mem_err:
                    logger.warning("auto memory: %s", mem_err)

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
