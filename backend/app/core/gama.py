from typing import List, Dict, Optional, Tuple, Any
import logging

from .context import ContextManager
from .memory import get_store, try_extract_memory
from .url_fetch import build_url_context
from .code_analyzer import build_query_context, detect_and_prepare
from .code_analyzer.pipeline import build_query_context_async
from .code_analyzer.source_detector import (
    extract_project_id,
    extract_pdf_id,
    extract_inline_code,
    parse_github_url,
    detect_level,
)
from .talk_skill import build_talk_layer
from .prompts import build_system_prompt
from ..config import settings
from ..web_search import should_search, search_web, _format_results

logger = logging.getLogger(__name__)


class GamaCore:
    def __init__(self, max_context_messages: int = 24):
        self.context_manager = ContextManager(max_messages=max_context_messages)

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

        if auto_memory and last_user:
            extracted = try_extract_memory(last_user)
            if extracted:
                try:
                    store.add_fact(extracted, source="auto")
                    fact_saved = extracted
                except Exception:
                    fact_saved = None

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

        conversational_mode = "20b" in (model or "").lower()

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
                last_user, user_id=user_id or "default"
            )
            if code_ctx:
                prepared.append({"role": "system", "content": code_ctx})
        except Exception as e:
            logger.warning("code_analyzer: %s", e)

        prepared.extend(context)
        return prepared, fact_saved, search_query, sources

    async def _code_analyzer_block(
        self, last_user: str, *, user_id: str = "default"
    ) -> str:
        """Prepara contexto de código sem mandar o projeto inteiro ao LLM."""
        if not last_user or not isinstance(last_user, str):
            return ""

        level = detect_level(last_user)
        max_tokens = {"quick": 2500, "targeted": 4500, "deep": 8000}.get(level, 4500)

        # 1) project_id / pdf_id já ingeridos
        pid = extract_project_id(last_user) or extract_pdf_id(last_user)
        if pid:
            try:
                return await build_query_context_async(
                    pid, last_user, max_tokens=max_tokens, level=level
                )
            except Exception:
                return build_query_context(
                    pid, last_user, max_tokens=max_tokens, level=level
                )

        # 2) URL GitHub na mensagem → ingest + contexto
        gh = parse_github_url(last_user)
        if gh:
            summary = await detect_and_prepare(last_user, user_id=user_id)
            if summary and summary.get("project_id"):
                pid = summary["project_id"]
                ctx = await build_query_context_async(
                    pid, last_user, max_tokens=max_tokens, level=level
                )
                header = (
                    f"[Code Analyzer] Repositório {summary.get('name')} indexado "
                    f"({summary.get('file_count', '?')} arquivos, "
                    f"frameworks={summary.get('frameworks')}). "
                    f"project_id={pid}\n"
                )
                return header + ctx
            if summary and summary.get("error"):
                return f"(Code Analyzer: falha ao indexar GitHub — {summary['error']})"

        # 3) código inline longo
        inline = extract_inline_code(last_user)
        if inline and len(inline) > 120:
            from .code_analyzer import ingest_direct_code

            summary = ingest_direct_code(inline, name="inline", user_id=user_id)
            pid = summary["project_id"]
            return build_query_context(
                pid, last_user, max_tokens=max_tokens, level=level
            )

        return ""
