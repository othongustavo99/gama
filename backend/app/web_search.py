"""
Busca na web — pensada para Railway (timeout curto, sem travar o chat).

Ordem:
  1) Brave (se BRAVE_API_KEY)
  2) Wikipedia OpenSearch (estável em datacenter)
  3) DuckDuckGo Instant Answer API
  4) duckduckgo-search (opcional, com timeout; costuma falhar em cloud)
"""

from __future__ import annotations

import asyncio
import logging
import re
from typing import Any
from urllib.parse import quote

import httpx

from .config import settings

logger = logging.getLogger(__name__)

SEARCH_TIMEOUT_SEC = float(
    getattr(settings, "WEB_SEARCH_TIMEOUT", None)
    or __import__("os").getenv("WEB_SEARCH_TIMEOUT", "8")
)

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
    if _QUESTION.search(text) and len(text) < 280:
        return True
    return False


def _format_results(results: list[dict[str, str]], query: str) -> str:
    if not results:
        return (
            f"[Busca na web: nenhuma fonte útil para “{query}”. "
            "Responda com o conhecimento disponível e avise a limitação.]"
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
    max_results = max(1, min(max_results, 6))

    try:
        return await asyncio.wait_for(
            _search_pipeline(query, max_results),
            timeout=SEARCH_TIMEOUT_SEC,
        )
    except asyncio.TimeoutError:
        logger.warning("web search timeout (%.1fs) q=%s", SEARCH_TIMEOUT_SEC, query[:80])
        return []
    except Exception as e:
        logger.warning("web search error: %s", e)
        return []


async def search_and_format(query: str, *, max_results: int = 5) -> str:
    results = await search_web(query, max_results=max_results)
    return _format_results(results, query)


async def _search_pipeline(query: str, max_results: int) -> list[dict[str, str]]:
    # 1) Brave
    if getattr(settings, "BRAVE_API_KEY", ""):
        try:
            got = await _search_brave(query, max_results)
            if got:
                return got
        except Exception as e:
            logger.warning("Brave: %s", e)

    # 2) Wikipedia (pt depois en)
    try:
        got = await _search_wikipedia(query, max_results, lang="pt")
        if len(got) < 2:
            got_en = await _search_wikipedia(query, max_results, lang="en")
            got = _merge(got, got_en, max_results)
        if got:
            return got
    except Exception as e:
        logger.warning("Wikipedia: %s", e)

    # 3) DDG Instant
    try:
        got = await _search_ddg_instant(query, max_results)
        if got:
            return got
    except Exception as e:
        logger.warning("DDG instant: %s", e)

    # 4) Pacote DDGS (opcional — muitos IPs de cloud bloqueiam)
    try:
        got = await asyncio.wait_for(_search_ddgs(query, max_results), timeout=5.0)
        if got:
            return got
    except Exception as e:
        logger.warning("DDGS: %s", e)

    return []


def _merge(a: list, b: list, limit: int) -> list:
    seen = set()
    out = []
    for item in a + b:
        u = item.get("url") or item.get("title")
        if u in seen:
            continue
        seen.add(u)
        out.append(item)
        if len(out) >= limit:
            break
    return out


async def _search_brave(query: str, max_results: int) -> list[dict[str, str]]:
    headers = {
        "Accept": "application/json",
        "X-Subscription-Token": settings.BRAVE_API_KEY,
    }
    async with httpx.AsyncClient(timeout=6.0) as client:
        r = await client.get(
            "https://api.search.brave.com/res/v1/web/search",
            headers=headers,
            params={"q": query, "count": max_results},
        )
        r.raise_for_status()
        data = r.json()
    out = []
    for item in (data.get("web") or {}).get("results") or []:
        out.append(
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("url") or ""),
                "snippet": str(item.get("description") or ""),
            }
        )
    return out


async def _search_wikipedia(
    query: str, max_results: int, *, lang: str
) -> list[dict[str, str]]:
    """API pública estável — funciona bem em VPS/Railway."""
    base = f"https://{lang}.wikipedia.org/w/api.php"
    params = {
        "action": "query",
        "list": "search",
        "srsearch": query,
        "srlimit": max_results,
        "format": "json",
        "utf8": 1,
    }
    headers = {"User-Agent": "Frequencia40-Gamma/0.6 (Railway; search assistant)"}
    async with httpx.AsyncClient(timeout=6.0, headers=headers) as client:
        r = await client.get(base, params=params)
        r.raise_for_status()
        data = r.json()

    out: list[dict[str, str]] = []
    for item in (data.get("query") or {}).get("search") or []:
        title = str(item.get("title") or "")
        snippet = re.sub(r"<[^>]+>", "", str(item.get("snippet") or ""))
        url = f"https://{lang}.wikipedia.org/wiki/{quote(title.replace(' ', '_'))}"
        out.append({"title": title, "url": url, "snippet": snippet})
    return out


async def _search_ddg_instant(query: str, max_results: int) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=6.0) as client:
        r = await client.get(
            "https://api.duckduckgo.com/",
            params={"q": query, "format": "json", "no_html": 1, "skip_disambig": 1},
            headers={"User-Agent": "Frequencia40-Gamma/0.6"},
        )
        r.raise_for_status()
        data: dict[str, Any] = r.json()

    out: list[dict[str, str]] = []
    abstract = (data.get("AbstractText") or "").strip()
    if abstract:
        out.append(
            {
                "title": str(data.get("Heading") or query),
                "url": str(data.get("AbstractURL") or ""),
                "snippet": abstract,
            }
        )
    for topic in data.get("RelatedTopics") or []:
        if len(out) >= max_results:
            break
        if not isinstance(topic, dict):
            continue
        if topic.get("Text"):
            out.append(
                {
                    "title": str(topic.get("Text") or "")[:90],
                    "url": str(topic.get("FirstURL") or ""),
                    "snippet": str(topic.get("Text") or ""),
                }
            )
    return out[:max_results]


async def _search_ddgs(query: str, max_results: int) -> list[dict[str, str]]:
    def _run() -> list[dict[str, str]]:
        try:
            from duckduckgo_search import DDGS
        except ImportError:
            try:
                from ddgs import DDGS  # type: ignore
            except ImportError:
                return []
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
