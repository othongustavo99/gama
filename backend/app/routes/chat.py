import json
import logging
import re

from fastapi import APIRouter, Header
from fastapi.responses import StreamingResponse

from ..core.gama import GamaCore
from ..llm import llm, LLMClient
from ..models import ChatRequest
from ..core.image_gen import wants_image_generation, build_image_prompt, generate_image
from ..config import settings as app_settings
from ..web_search import should_search, search_web
from ..core.memory import get_store, extract_facts_with_llm
from ..core.image_analyzer import analyze_images
from ..core.code_analyzer.pipeline import build_query_context_async

logger = logging.getLogger(__name__)
router = APIRouter()
gama = GamaCore()

_PROJECT_ID_RE = re.compile(r"\[project_id:([A-Za-z0-9_-]{6,128})\]", re.IGNORECASE)
_DEEP_PROJECT_INTENT = re.compile(
    r"\b(analisa(?:r|e)?|revise|revisar|audita(?:r|e)?|corrija|corrigir|"
    r"melhore|melhorar|refatora(?:r|e)?|polir|polida|c[oó]digos? completos?|"
    r"arquivos? completos?|prontos? para substituir|projeto inteiro|zip inteiro)\b",
    re.IGNORECASE,
)


def _message_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            str(part.get("text") or "")
            for part in content
            if isinstance(part, dict)
        )
    return str(content or "")


def _attached_project_id(messages: list[dict]) -> str | None:
    # O ID costuma estar na mensagem em que o ZIP foi anexado, não na pergunta
    # posterior. Procuramos no histórico recebido, sem acionar análise ainda.
    for message in reversed(messages):
        match = _PROJECT_ID_RE.search(_message_text(message.get("content")))
        if match:
            return match.group(1)
    return None


@router.get("/models")
async def list_models():
    models = await llm.list_models()
    return {"models": models, "provider": llm.provider}


@router.post("/chat")
async def chat(
    request: ChatRequest,
    x_user_id: str | None = Header(default=None, alias="X-User-Id"),
):
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

    # ZIPs são indexados no momento do anexo; ler o conteúdo para o modelo é
    # deliberadamente sob demanda. Conversa comum não chama o analisador.
    project_id = _attached_project_id(messages)
    deep_project_review = bool(
        project_id and _DEEP_PROJECT_INTENT.search(last_user)
    )

    has_imgs = bool(getattr(request, "images", None))
    want_image_gen = bool(
        getattr(app_settings, "IMAGE_GEN_ENABLED", True)
        and last_user
        and wants_image_generation(last_user, has_attached_images=has_imgs)
    )

    # Image Analyzer: faz a leitura visual eficiente antes do modelo principal.
    # Se falhar, o fluxo multimodal antigo continua como fallback.
    image_analysis_context = ""
    image_analysis_ok = False
    vision_model = None
    if getattr(request, "images", None):
        from ..config import settings as _settings
        vision_model = (
            getattr(_settings, "VISION_MODEL", None)
            or model
        )

    async def stream_with_meta():
        sources: list = []
        search_query = None
        fact_saved = None
        gama_messages = None

        try:
            nonlocal image_analysis_context, image_analysis_ok
            # --- fase: geração de imagem (quando o usuário pede para criar/imaginar) ---
            if want_image_gen:
                yield json.dumps(
                    {"gama_meta": {"phase": "generating_image"}},
                    ensure_ascii=False,
                ) + "\n"
                prompt = build_image_prompt(last_user)
                result = await generate_image(prompt)
                if result.get("ok") and result.get("base64"):
                    yield json.dumps(
                        {
                            "gama_meta": {
                                "phase": "image_ready",
                                "image": {
                                    "mime": result.get("mime") or "image/png",
                                    "data": result["base64"],
                                    "model": result.get("model"),
                                    "prompt": result.get("prompt") or prompt[:200],
                                },
                            }
                        },
                        ensure_ascii=False,
                    ) + "\n"
                    # legenda curta via modelo de texto
                    caption_messages = [
                        {
                            "role": "system",
                            "content": (
                                "Você é a Gamma. O usuário pediu uma imagem e ela já foi gerada. "
                                "Responda em 1-3 frases em português, confirmando o que foi criado, "
                                "sem markdown de imagem e sem pedir desculpas. Seja natural."
                            ),
                        },
                        {"role": "user", "content": last_user},
                    ]
                    async for chunk in llm.stream_chat(model=model, messages=caption_messages):
                        yield chunk
                    return
                else:
                    err = result.get("error") or "falha desconhecida"
                    yield json.dumps(
                        {
                            "gama_meta": {
                                "phase": "image_failed",
                                "error": err,
                            }
                        },
                        ensure_ascii=False,
                    ) + "\n"
                    # continua o chat normal com aviso no system
                    # avisa no fluxo via token sintético
                    yield json.dumps(
                        {
                            "message": {
                                "role": "assistant",
                                "content": (
                                    f"Não consegui gerar a imagem agora ({err}). "
                                    "Pode tentar de novo com uma descrição um pouco diferente?"
                                ),
                            },
                            "done": False,
                        },
                        ensure_ascii=False,
                    ) + "\n"
                    yield json.dumps(
                        {"message": {"role": "assistant", "content": ""}, "done": True},
                        ensure_ascii=False,
                    ) + "\n"
                    return

            # --- fase: Image Analyzer ---
            if getattr(request, "images", None):
                yield json.dumps(
                    {"gama_meta": {"phase": "image_analyzing"}},
                    ensure_ascii=False,
                ) + "\n"
                img_for_analysis = [
                    {"mime": i.mime, "data": i.data, "name": i.name}
                    for i in request.images
                    if i.data
                ]
                try:
                    image_analysis_context = await analyze_images(
                        images=img_for_analysis,
                        query=last_user,
                        llm_client=llm,
                        model=vision_model or model,
                    )
                    image_analysis_ok = bool(image_analysis_context.strip())
                except Exception as image_err:
                    logger.warning("image analyzer: %s", image_err)
                    image_analysis_context = ""
                    image_analysis_ok = False

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
                uid = (x_user_id or request.user_id or "default").strip() or "default"
                gama_messages, fact_saved, search_query, sources = await gama.build_messages(
                    messages,
                    model=model,
                    ollama_client=llm,
                    prefetched_sources=sources if will_search else None,
                    prefetched_query=search_query,
                    user_id=uid,
                    auto_memory=getattr(request, "auto_memory", True),
                    voice_mode=bool(getattr(request, "voice_mode", False)),
                    chat_mode=getattr(request, "chat_mode", None),
                    conversation_id=getattr(request, "conversation_id", None),
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

            # Só faz a leitura profunda quando o usuário pede revisão/correção.
            # O índice do ZIP fica no backend entre mensagens; não pedimos reenvio.
            if deep_project_review and project_id:
                yield json.dumps(
                    {"gama_meta": {"phase": "project_analyzing", "project_id": project_id}},
                    ensure_ascii=False,
                ) + "\n"
                try:
                    project_context = await build_query_context_async(
                        project_id,
                        last_user,
                        max_tokens=7000,
                        level="deep",
                    )
                    if project_context.strip():
                        gama_messages.append({
                            "role": "system",
                            "content": (
                                "ANÁLISE SOB DEMANDA DO PROJETO ANEXADO. Use o contexto do Code Analyzer "
                                "como fonte real do código. Não afirme ter lido um arquivo cujo conteúdo "
                                "não aparece no contexto. Para devolver um arquivo completo, confirme que "
                                "o conteúdo original necessário está disponível; se faltar, solicite/recupere "
                                "o path antes de reescrever. Priorize achados concretos, dependências e "
                                "correções seguras.\n\n" + project_context
                            ),
                        })
                    else:
                        gama_messages.append({
                            "role": "system",
                            "content": (
                                "O usuário pediu análise profunda do ZIP, mas o Code Analyzer não retornou "
                                "contexto utilizável. Informe a falha claramente e não invente análise nem código."
                            ),
                        })
                except Exception as project_err:
                    logger.exception("deep project analysis failed: %s", project_err)
                    gama_messages.append({
                        "role": "system",
                        "content": (
                            "A análise profunda do projeto falhou nesta rodada. Informe ao usuário que houve "
                            "uma falha ao recuperar o contexto do projeto; não diga que leu os arquivos e não "
                            "invente códigos completos."
                        ),
                    })

            if image_analysis_ok:
                gama_messages.append(
                    {
                        "role": "system",
                        "content": image_analysis_context,
                    }
                )

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
            if getattr(request, "images", None) and not image_analysis_ok:
                img_payload = [
                    {"mime": i.mime, "data": i.data, "name": i.name}
                    for i in request.images
                    if i.data
                ]

            # Fallback multimodal antigo: somente se o Image Analyzer não
            # conseguiu produzir contexto. Quando ele funciona, a imagem não
            # é reenviada ao modelo principal, economizando tokens visuais.
            active_model = model
            if img_payload:
                from ..config import settings as _settings
                if llm.provider == "ollama":
                    active_model = (
                        getattr(_settings, "VISION_MODEL", None)
                        or "qwen2-vl"
                    )
                else:
                    # openrouter (padrão)
                    active_model = (
                        getattr(_settings, "VISION_MODEL", None)
                        or "google/gemini-2.5-flash"
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
                            "image_analyzer_fallback": True,
                        }
                    },
                    ensure_ascii=False,
                ) + "\n"
            elif getattr(request, "images", None):
                yield json.dumps(
                    {
                        "gama_meta": {
                            "phase": "thinking",
                            "image_analyzer": True,
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


            # ── ZIP automático a partir de [[GAMA_FILES]] ──
            try:
                full_assistant = "".join(assistant_acc)
                if "[[GAMA_FILES]]" in full_assistant or _wants_zip_delivery(last_user):
                    artifact_meta = _try_build_zip_from_assistant(
                        full_assistant,
                        last_user=last_user,
                        user_id=(x_user_id or getattr(request, "user_id", None) or "default"),
                    )
                    if artifact_meta:
                        yield json.dumps(
                            {"gama_meta": {"phase": "artifact_ready", "artifact": artifact_meta}},
                            ensure_ascii=False,
                        ) + "\n"
            except Exception as zip_err:
                logger.warning("zip from assistant: %s", zip_err)

            # Memória automática pós-turno
            if getattr(request, "auto_memory", True):
                try:
                    u = (x_user_id or getattr(request, "user_id", None) or "default")
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
