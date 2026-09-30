from typing import List, Dict, Optional, Tuple
import logging

from .context import ContextManager
from .memory import memory_store, try_extract_memory
from .prompts import build_system_prompt
from ..config import settings
from ..web_search import should_search, search_and_format

logger = logging.getLogger(__name__)


class GamaCore:
    def __init__(self, max_context_messages: int = 24):
        self.context_manager = ContextManager(
            max_messages=max_context_messages
        )

    async def build_messages(
        self,
        messages: List[Dict[str, str]],
        *,
        model: str,
        ollama_client,
        auto_memory: bool = True,
        enable_web_search: bool = True,
    ) -> Tuple[List[Dict[str, str]], Optional[str], Optional[str]]:
        fact_saved: Optional[str] = None
        search_query: Optional[str] = None
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
                    memory_store.add_fact(extracted, source="auto")
                    fact_saved = extracted
                except Exception:
                    fact_saved = None

        web_on = enable_web_search and getattr(
            settings, "WEB_SEARCH_ENABLED", True
        )
        if web_on and last_user and should_search(last_user):
            query = last_user.strip()
            if len(query) > 200:
                query = query[:200]
            search_query = query
            try:
                web_block = await search_and_format(query, max_results=5)
            except Exception as e:
                logger.warning("search_and_format: %s", e)
                web_block = (
                    "[Busca na web indisponível no momento. "
                    "Responda com cautela e diga que não conseguiu pesquisar.]"
                )

        try:
            memory_block = memory_store.as_prompt_block()
        except Exception:
            memory_block = ""

        system_prompt = build_system_prompt(
            memory_block=memory_block,
            web_enabled=web_on,
        )

        async def _summarize(older: List[Dict[str, str]]) -> str:
            sample = older[-20:] if len(older) > 20 else older
            transcript_lines = []
            for m in sample:
                role = "Usuário" if m.get("role") == "user" else "Gamma"
                text = (m.get("content") or "").replace("\n", " ")
                if len(text) > 200:
                    text = text[:200] + "…"
                transcript_lines.append(f"{role}: {text}")
            transcript = "\n".join(transcript_lines)
            prompt = (
                "Resuma em português, em no máximo 8 frases curtas, "
                "os pontos importantes desta conversa. "
                "Foque em decisões, fatos, preferências e tarefas. "
                "Não invente nada.\n\n"
                f"{transcript}"
            )
            return await ollama_client.chat_once(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                timeout=60.0,
            )

        try:
            context = await self.context_manager.prepare(
                messages,
                summarize=_summarize,
            )
        except Exception as e:
            logger.warning("context prepare failed: %s", e)
            context = messages[-16:]

        prepared: List[Dict[str, str]] = [
            {"role": "system", "content": system_prompt},
        ]
        if web_block:
            prepared.append({"role": "system", "content": web_block})
        prepared.extend(context)
        return prepared, fact_saved, search_query
