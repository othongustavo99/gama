import asyncio
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

# Mantém referência das tarefas em background para o GC não cancelá-las.
_bg_tasks: set[asyncio.Task] = set()


async def _save_memory_bg(
    user_id: str, user_text: str, assistant_text: str, model: str
) -> None:
    """Extrai e salva fatos DEPOIS que a resposta já foi entregue ao app."""
    try:
        store = get_store(user_id)
        existing = [f.get("text", "") for f in store.list_facts()]
        new_facts = await extract_facts_with_llm(
            user_text=user_text,
            assistant_text=assistant_text,
            model=model,
            llm_client=llm,
            existing_facts=existing,
        )
        store.add_facts(new_facts, source="auto")
    except Exception as mem_err:
        logger.warning("auto memory: %s", mem_err)


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
                vision = (getattr(_settings, "VISION_MODEL", None) or "").strip()
                # Modelo de visão SÓ quando há imagem; senão mantém o modelo de chat.
                if vision:
                    active_model = vision
                elif llm.provider == "ollama":
                    active_model = "llava"
                # groq sem VISION_MODEL: mantém active_model (texto) + nota no inject
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

            # Memória automática pós-turno: roda em background para a
            # conexão fechar logo após o último token (antes, o app ficava
            # "digitando" até a chamada extra ao LLM terminar).
            if getattr(request, "auto_memory", True) and last_user.strip():
                u = (getattr(request, "user_id", None) or "default").strip() or "default"
                task = asyncio.create_task(
                    _save_memory_bg(u, last_user, "".join(assistant_acc), model)
                )
                _bg_tasks.add(task)
                task.add_done_callback(_bg_tasks.discard)

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
