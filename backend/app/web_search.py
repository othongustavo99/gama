"""
Busca na web para a Gamma.

Usa DuckDuckGo (sem API key) por padrão.
Opcional: BRAVE_API_KEY para Brave Search.
"""

from __future__ import annotations

import logging
import re
from typing import Any

import httpx

from .config import settings

logger = logging.getLogger(__name__)

# Gatilhos explícitos + perguntas que costumam precisar de dados atuais
_EXPLICIT = re.compile(
    r"\b("
    r"pesquisa(?:r)?|busc(?:a|ar)|google|na\s+internet|web\s*search|"
    r"o\s+que\s+est[aá]\s+acontecendo|not[ií]cia|"
    r"pre[cç]o\s+(?:atual|hoje|agora)|cota[cç][aã]o|"
    r"hoje\s+(?:e|é)\s+dia|quem\s+ganhou|resultado\s+do\s+jogo|"
    r"vers[aã]o\s+mais\s+recente|lan[cç]amento\s+de"
    r")\b",
    re.IGNORECASE,
)

_QUESTION = re.compile(
    r"^\s*(?:o\s+que|quem|quando|onde|qual|quais|como|por\s+que|porque|"
    r"what|who|when|where|which|how|why)\b",
    re.IGNORECASE,
)

_SKIP = re.compile(
    r"\b("
    r"lembre|mem[oó]ria|/memoria|escreva\s+um\s+c[oó]digo|refatore|"
    r"corrija\s+este|analise\s+este\s+arquivo|s[oó]\s+converse"
    r")\b",
    re.IGNORECASE,
)


def should_search(user_text: str) -> bool:
    text = (user_text or "").strip()
    if len(text) < 8:
        return False
    if _SKIP.search(text):
        return False
    if _EXPLICIT.search(text):
        return True
    # perguntas curtas/factuais genéricas
    if _QUESTION.search(text) and len(text) < 280:
        return True
    return False


def _format_results(results: list[dict[str, str]], query: str) -> str:
    if not results:
        return (
            f"[Busca na web: nenhuma fonte útil para “{query}”. "
            "Responda com o que souber e deixe claro a limitação.]"
        )
    lines = [
        f"[Resultados de busca na web para: “{query}”]",
        "Use estas fontes. Não invente links. Cite títulos quando fizer sentido.",
        "",
    ]
    for i, r in enumerate(results, 1):
        title = r.get("title") or "Sem título"
        url = r.get("url") or ""
        snippet = r.get("snippet") or ""
        lines.append(f"{i}. {title}")
        if url:
            lines.append(f"   URL: {url}")
        if snippet:
            lines.append(f"   {snippet}")
        lines.append("")
    return "\n".join(lines).strip()


async def search_web(query: str, *, max_results: int = 5) -> list[dict[str, str]]:
    query = (query or "").strip()
    if not query:
        return []

    max_results = max(1, min(max_results, 8))

    # 1) Brave se houver chave
    if getattr(settings, "BRAVE_API_KEY", ""):
        try:
            return await _search_brave(query, max_results)
        except Exception as e:
            logger.warning("Brave search falhou: %s", e)

    # 2) DuckDuckGo (pacote)
    try:
        return await _search_ddgs(query, max_results)
    except Exception as e:
        logger.warning("DDGS falhou: %s", e)

    # 3) DuckDuckGo instant answer API (limitado, mas sem dependência extra)
    try:
        return await _search_ddg_instant(query, max_results)
    except Exception as e:
        logger.warning("DDG instant falhou: %s", e)

    return []


async def search_and_format(query: str, *, max_results: int = 5) -> str:
    results = await search_web(query, max_results=max_results)
    return _format_results(results, query)


async def _search_ddgs(query: str, max_results: int) -> list[dict[str, str]]:
    """duckduckgo_search / ddgs — roda em thread para não bloquear."""
    import asyncio

    def _run() -> list[dict[str, str]]:
        try:
            from duckduckgo_search import DDGS
        except ImportError:
            from ddgs import DDGS  # type: ignore

        out: list[dict[str, str]] = []
        with DDGS() as ddgs:
            for item in ddgs.text(query, max_results=max_results):
                out.append(
                    {
                        "title": str(item.get("title") or ""),
                        "url": str(item.get("href") or item.get("link") or ""),
                        "snippet": str(item.get("body") or item.get("snippet") or ""),
                    }
                )
        return out

    return await asyncio.to_thread(_run)


async def _search_brave(query: str, max_results: int) -> list[dict[str, str]]:
    key = settings.BRAVE_API_KEY
    headers = {
        "Accept": "application/json",
        "X-Subscription-Token": key,
    }
    params = {"q": query, "count": max_results}
    async with httpx.AsyncClient(timeout=15.0) as client:
        r = await client.get(
            "https://api.search.brave.com/res/v1/web/search",
            headers=headers,
            params=params,
        )
        r.raise_for_status()
        data = r.json()
    out: list[dict[str, str]] = []
    for item in (data.get("web") or {}).get("results") or []:
        out.append(
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("url") or ""),
                "snippet": str(item.get("description") or ""),
            }
        )
    return out


async def _search_ddg_instant(query: str, max_results: int) -> list[dict[str, str]]:
    """Fallback leve da API pública do DuckDuckGo."""
    async with httpx.AsyncClient(timeout=12.0) as client:
        r = await client.get(
            "https://api.duckduckgo.com/",
            params={
                "q": query,
                "format": "json",
                "no_html": 1,
                "skip_disambig": 1,
            },
        )
        r.raise_for_status()
        data: dict[str, Any] = r.json()

    out: list[dict[str, str]] = []
    abstract = (data.get("AbstractText") or "").strip()
    abstract_url = (data.get("AbstractURL") or "").strip()
    heading = (data.get("Heading") or query).strip()
    if abstract:
        out.append(
            {
                "title": heading,
                "url": abstract_url,
                "snippet": abstract,
            }
        )

    for topic in data.get("RelatedTopics") or []:
        if len(out) >= max_results:
            break
        if not isinstance(topic, dict):
            continue
        if "Text" in topic:
            out.append(
                {
                    "title": str(topic.get("Text") or "")[:80],
                    "url": str(topic.get("FirstURL") or ""),
                    "snippet": str(topic.get("Text") or ""),
                }
            )
        for sub in topic.get("Topics") or []:
            if len(out) >= max_results:
                break
            if isinstance(sub, dict) and sub.get("Text"):
                out.append(
                    {
                        "title": str(sub.get("Text") or "")[:80],
                        "url": str(sub.get("FirstURL") or ""),
                        "snippet": str(sub.get("Text") or ""),
                    }
                )
    return out[:max_results]
