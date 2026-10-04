from typing import List, Dict, Optional, Tuple, Any
import logging

from .context import ContextManager
from .memory import get_store, try_extract_memory
from .url_fetch import build_url_context
from .project_analyzer import build_query_context
import re as _re
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

        system_prompt = build_system_prompt(
            memory_block=memory_block,
            web_enabled=web_on,
        )

        # Resume localmente: chamar o modelo de novo aqui pode bloquear o turno por até 60 s.
        try:
            context = await self.context_manager.prepare(messages)
        except Exception as e:
            logger.warning("context: %s", e)
            context = messages[-16:]

        url_block = ""
        try:
            if last_user and isinstance(last_user, str) and "http" in last_user.lower():
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

        # Project Analyzer: marker [project_id:xxxx] no texto do usuário
        try:
            pid = None
            if last_user and isinstance(last_user, str):
                m = _re.search(r"\[project_id:([a-zA-Z0-9_\-]{6,32})\]", last_user)
                if m:
                    pid = m.group(1)
            if pid:
                # limpa marker da última user msg no contexto se possível
                proj_ctx = build_query_context(pid, last_user, max_tokens=4500)
                prepared.append({"role": "system", "content": proj_ctx})
        except Exception as e:
            logger.warning("project_analyzer: %s", e)

        prepared.extend(context)
        return prepared, fact_saved, search_query, sources
