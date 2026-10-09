from typing import List, Dict, Optional, Tuple, Any
import logging

from .context import ContextManager
from .memory import get_store, try_extract_memories
from .url_fetch import build_url_context
from .code_analyzer import build_query_context, detect_and_prepare
from .code_analyzer.pipeline import build_query_context_async
from .code_analyzer.source_detector import (
    extract_project_id,
    extract_pdf_id,
    extract_inline_code,
    extract_need_more_paths,
    parse_github_url,
    detect_level,
)
from .talk_skill import build_talk_layer
try:
    from .conversation_session import (
        session_key,
        load_session,
        save_session,
        update_from_user_message,
        set_active_project,
        add_action,
        as_prompt_block,
    )
except ImportError:  # arquivo ainda não no deploy — app sobe sem sessão
    def session_key(user_id=None, conversation_id=None, messages=None):
        return "noop"

    def load_session(key):
        return {}

    def save_session(data):
        return None

    def update_from_user_message(session, text):
        return session or {}

    def set_active_project(session, **kwargs):
        return session or {}

    def add_action(session, action):
        return session or {}

    def as_prompt_block(session):
        return ""
from .prompts import build_system_prompt
from ..config import settings
from ..web_search import should_search, search_web, _format_results

logger = logging.getLogger(__name__)


class GamaCore:
    def __init__(self, max_context_messages: int = 24):
        self.context_manager = ContextManager(max_messages=max(max_context_messages, 48))

    async def build_messages(
        self,
        messages: List[Dict[str, str]],
        *,
        model: str,
        ollama_client,
        auto_memory: bool = True,
        enable_web_search: bool = True,
        prefetched_sources: Optional[List[Dict[str, str]]] = None,
        prefetched_query: Optional[str] = None,
        user_id: Optional[str] = None,
        voice_mode: bool = False,
        conversation_id: Optional[str] = None,
        chat_mode: Optional[str] = None,
    ) -> Tuple[List[Dict[str, str]], Optional[str], Optional[str], List[Dict[str, str]]]:
        """
        Returns: prepared, fact_saved, search_query, sources
        """
        store = get_store(user_id)
        fact_saved: Optional[str] = None
        search_query: Optional[str] = prefetched_query
        sources: List[Dict[str, str]] = list(prefetched_sources or [])
        web_block = ""

        last_user = ""
        if messages:
            last = messages[-1]
            if last.get("role") == "user":
                last_user = last.get("content") or ""

        # ── Sessão desta conversa (projeto, links, arquivos, ações) ──
        skey = session_key(user_id, conversation_id, messages)
        session = load_session(skey)
        if last_user:
            session = update_from_user_message(session, last_user)

        # Recupera project_id de mensagens anteriores (ZIP já anexado nesta conversa)
        if not session.get("active_project_id") and messages:
            for m in reversed(messages[-12:]):
                content = m.get("content") or ""
                if isinstance(content, list):
                    content = " ".join(
                        str(p.get("text") or "") for p in content if isinstance(p, dict)
                    )
                pid_hist = extract_project_id(str(content))
                if pid_hist:
                    set_active_project(
                        session, project_id=pid_hist, source="history"
                    )
                    break

        if auto_memory and last_user:
            try:
                for extracted in try_extract_memories(last_user):
                    try:
                        store.add_fact(extracted, source="auto")
                        fact_saved = fact_saved or extracted
                    except Exception as e:
                        logger.warning("memory add: %s", e)
            except Exception as e:
                logger.warning("memory extract: %s", e)

        web_on = enable_web_search and getattr(settings, "WEB_SEARCH_ENABLED", True)

        if web_on and last_user and should_search(last_user):
            query = last_user.strip()[:200]
            search_query = query
            if not sources:
                try:
                    sources = await search_web(query, max_results=5)
                except Exception as e:
                    logger.warning("search: %s", e)
                    sources = []
            web_block = _format_results(sources, query)

        try:
            memory_block = store.as_prompt_block()
        except Exception:
            memory_block = ""

        mode = (chat_mode or "").strip().lower()
        conversational_mode = mode in {"conversar", "conversation", "conversational"} or (
            "20b" in (model or "").lower() and mode != "programar"
        )
        programming_mode = mode in {"programar", "coding", "code"} or (
            not conversational_mode and not voice_mode
        )

        # Sinais para a Talk Skill (antes de montar o system prompt)
        has_project = bool(
            extract_project_id(last_user) or extract_pdf_id(last_user)
        )
        has_code_hint = bool(
            has_project
            or parse_github_url(last_user)
            or extract_inline_code(last_user)
        )

        talk_mode, talk_layer = build_talk_layer(
            last_user,
            messages=messages,
            voice_mode=voice_mode,
            has_code_context=has_code_hint,
            has_project_context=has_project,
            has_web_block=bool(web_block),
            # modelo leve (20b) favorece conversational se não houver tarefa técnica
            force_mode=("conversational" if conversational_mode and not has_code_hint else None),
        )

        system_prompt = build_system_prompt(
            memory_block=memory_block,
            web_enabled=web_on,
            voice_mode=voice_mode,
            conversational_mode=conversational_mode,
            programming_mode=programming_mode and not conversational_mode,
            talk_layer=talk_layer,
            talk_mode=talk_mode,
        )

        # Resume localmente: chamar o modelo de novo aqui pode bloquear o turno por até 60 s.
        try:
            context = await self.context_manager.prepare(messages)
        except Exception as e:
            logger.warning("context: %s", e)
            context = messages[-16:]

        url_block = ""
        # Se for GitHub de código, o Code Analyzer cuida — evita duplicar fetch genérico
        is_github_code = bool(parse_github_url(last_user)) if last_user else False
        try:
            if (
                last_user
                and isinstance(last_user, str)
                and "http" in last_user.lower()
                and not is_github_code
            ):
                url_block = await build_url_context(last_user)
        except Exception as e:
            logger.warning("url_context: %s", e)

        prepared: List[Dict[str, str]] = [
            {"role": "system", "content": system_prompt},
        ]
        if web_block:
            prepared.append({"role": "system", "content": web_block})
        if url_block:
            prepared.append({"role": "system", "content": url_block})

        # ── Code Analyzer ────────────────────────────────────────────────
        try:
            code_ctx = await self._code_analyzer_block(
                last_user,
                user_id=user_id or "default",
                session=session,
                messages=messages,
            )
            if code_ctx:
                prepared.append({"role": "system", "content": code_ctx})
                if session.get("active_project_id"):
                    add_action(
                        session,
                        f"Contexto de código injetado (project_id={session['active_project_id']})",
                    )
        except Exception as e:
            logger.warning("code_analyzer: %s", e)

        # Estado da conversa (projeto, arquivos, ações) — sempre no system
        try:
            sess_block = as_prompt_block(session)
            if sess_block:
                prepared.append({"role": "system", "content": sess_block})
            save_session(session)
        except Exception as e:
            logger.warning("conversation_session: %s", e)

        prepared.extend(context)

        # Memória também logo ANTES da última mensagem do usuário: modelos pequenos
        # dão mais peso ao que está perto da pergunta do que ao fim de um system longo.
        if memory_block:
            reminder = {"role": "system", "content": memory_block}
            idx = None
            for i in range(len(prepared) - 1, -1, -1):
                if prepared[i].get("role") == "user":
                    idx = i
                    break
            if idx is None:
                prepared.append(reminder)
            else:
                prepared.insert(idx, reminder)

        return prepared, fact_saved, search_query, sources

    async def _code_analyzer_block(
        self,
        last_user: str,
        *,
        user_id: str = "default",
        session: Optional[dict] = None,
        messages: Optional[List[Dict[str, str]]] = None,
    ) -> str:
        """Prepara contexto de código sem mandar o projeto inteiro ao LLM."""
        if not last_user or not isinstance(last_user, str):
            # ainda pode haver projeto ativo na sessão
            if not (session and session.get("active_project_id")):
                return ""
            last_user = last_user or ""

        level = detect_level(last_user or "analise o projeto")
        max_tokens = {"quick": 2500, "targeted": 4500, "deep": 8000}.get(level, 4500)

        # paths explícitos: [need_more:a,b] ou lib/.../file.dart no texto do usuário
        extra_paths = extract_need_more_paths(last_user or "")
        # nomes como main.dart / context.py → força carregamento integral
        try:
            from .code_analyzer.code_search import (
                extract_mentioned_filenames,
                find_matching_paths,
            )
            mentioned = extract_mentioned_filenames(last_user or "")
            if mentioned:
                for m in mentioned:
                    if m not in extra_paths:
                        extra_paths.append(m)
        except Exception:
            pass

        # Pedido de código integral / "me de o código" (follow-up sem path)
        qlow = (last_user or "").lower()
        wants_codes = any(
            k in qlow
            for k in (
                "códigos completos",
                "codigos completos",
                "código completo",
                "codigo completo",
                "conteúdo completo",
                "conteudo completo",
                "prontos para substituir",
                "me de os codigo",
                "me dê os código",
                "me de o codigo",
                "me dê o código",
                "me de o código",
                "me dê o codigo",
                "exatamente o codigo",
                "exatamente o código",
                "o codigo completo",
                "o código completo",
                "mostra o codigo",
                "mostra o código",
                "cole o codigo",
                "cole o código",
                "reproduz o codigo",
                "reproduz o código",
                "código exato",
                "codigo exato",
                "texto integral",
                "arquivo completo",
                "na íntegra",
                "na integra",
                "full content",
                "entire file",
            )
        )

        def _collect_paths_from_text(text: str) -> list[str]:
            found: list[str] = []
            try:
                from .code_analyzer.code_search import extract_mentioned_filenames
                found.extend(extract_mentioned_filenames(text or ""))
            except Exception:
                pass
            found.extend(extract_need_more_paths(text or ""))
            return found

        # Se pediu o código mas não citou arquivo nesta mensagem:
        # 1) sessão (files_mentioned)
        # 2) mensagens recentes do usuário
        # 3) última resposta da assistente (paths / need_more)
        if wants_codes and not extra_paths:
            for fm in (session or {}).get("files_mentioned") or []:
                if fm and fm not in extra_paths:
                    extra_paths.append(fm)
            if messages:
                for m in reversed(messages[-12:]):
                    content = m.get("content") or ""
                    if isinstance(content, list):
                        content = " ".join(
                            str(p.get("text") or "")
                            for p in content
                            if isinstance(p, dict)
                        )
                    for path in _collect_paths_from_text(str(content)):
                        if path and path not in extra_paths:
                            extra_paths.append(path)
                    if len(extra_paths) >= 8:
                        break

        # Mesmo sem frase "código completo": se há projeto ativo e a msg
        # só pede o arquivo já discutido, força reload
        if not extra_paths and session and session.get("files_mentioned"):
            if any(
                k in qlow
                for k in (
                    "esse arquivo",
                    "este arquivo",
                    "o arquivo",
                    "dele",
                    "desse arquivo",
                    "código",
                    "codigo",
                )
            ):
                for fm in session.get("files_mentioned") or []:
                    if fm and fm not in extra_paths:
                        extra_paths.append(fm)

        if wants_codes or extra_paths:
            level = "deep"
            max_tokens = min(max(max_tokens, 6000), 10000)
        if extra_paths:
            level = "deep"
            max_tokens = min(max(max_tokens, 5000 + 2500 * len(extra_paths)), 12000)

        # 1) URL GitHub NA MENSAGEM ATUAL → prioridade (não ficar preso no ZIP antigo)
        gh_now = parse_github_url(last_user)
        if gh_now:
            summary = await detect_and_prepare(last_user, user_id=user_id)
            if summary and summary.get("project_id"):
                pid = summary["project_id"]
                if session is not None:
                    set_active_project(
                        session,
                        project_id=pid,
                        name=summary.get("name"),
                        source=summary.get("source") or "github",
                    )
                    session["github_url"] = gh_now.get("url") or session.get("github_url")
                    if summary.get("name"):
                        add_action(session, f"Indexou GitHub {summary.get('name')}")
                ctx = await build_query_context_async(
                    pid,
                    last_user,
                    max_tokens=max_tokens,
                    level=level,
                    extra_paths=extra_paths or None,
                )
                header = (
                    f"[Code Analyzer] Repositório {summary.get('name')} indexado "
                    f"({summary.get('file_count', '?')} arquivos, "
                    f"frameworks={summary.get('frameworks')}). "
                    f"project_id={pid}\n"
                    "Instrução: o contexto abaixo contém arquivos deste GitHub. "
                    "Se o usuário pediu um arquivo pelo nome, o conteúdo está (ou deveria estar) "
                    "neste bloco — responda com base nele e NÃO diga que não tem o arquivo.\n"
                )
                return header + (ctx or "")
            if summary and summary.get("error"):
                return (
                    f"(Code Analyzer: falha ao indexar GitHub — {summary['error']}. "
                    "Verifique se o repo é público ou se GITHUB_TOKEN está configurado no backend.)"
                )

        # 2) project_id / pdf_id na mensagem OU projeto ativo da conversa
        pid = extract_project_id(last_user) or extract_pdf_id(last_user)
        if not pid and session and session.get("active_project_id"):
            pid = session["active_project_id"]
        if pid:
            if session is not None and not session.get("active_project_id"):
                set_active_project(session, project_id=pid, source="marker")
            try:
                return await build_query_context_async(
                    pid,
                    last_user or "contexto do projeto",
                    max_tokens=max_tokens,
                    level=level,
                    extra_paths=extra_paths or None,
                )
            except Exception:
                return build_query_context(
                    pid,
                    last_user or "contexto do projeto",
                    max_tokens=max_tokens,
                    level=level,
                    extra_paths=extra_paths or None,
                )

        # 3) GitHub só na sessão (sem URL nesta mensagem)
        gh = None
        if session and session.get("github_url"):
            gh = parse_github_url(session["github_url"])
            if gh and last_user and session["github_url"] not in last_user:
                last_user = f"{last_user}\n{session['github_url']}"
        if gh:
            summary = await detect_and_prepare(
                session.get("github_url") or last_user, user_id=user_id
            )
            if summary and summary.get("project_id"):
                pid = summary["project_id"]
                if session is not None:
                    set_active_project(
                        session,
                        project_id=pid,
                        name=summary.get("name"),
                        source=summary.get("source") or "github",
                    )
                ctx = await build_query_context_async(
                    pid, last_user, max_tokens=max_tokens, level=level, extra_paths=extra_paths or None
                )
                header = (
                    f"[Code Analyzer] Repositório {summary.get('name')} "
                    f"(project_id={pid})\n"
                )
                return header + (ctx or "")
            if summary and summary.get("error"):
                return f"(Code Analyzer: falha ao indexar GitHub — {summary['error']})"

        # 3) código inline longo
        inline = extract_inline_code(last_user)
        if inline and len(inline) > 120:
            from .code_analyzer import ingest_direct_code

            summary = ingest_direct_code(inline, name="inline", user_id=user_id)
            pid = summary["project_id"]
            return build_query_context(
                pid, last_user, max_tokens=max_tokens, level=level, extra_paths=extra_paths or None
            )

        return ""
