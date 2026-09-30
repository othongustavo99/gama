"""
Rede ampliada de busca na web para a Gamma (Railway-safe).

Fontes (em paralelo quando possível):
  - Brave Search API          (BRAVE_API_KEY)
  - Serper / Google           (SERPER_API_KEY)
  - Tavily                    (TAVILY_API_KEY)
  - Wikipedia pt + en
  - Wikidata
  - Stack Exchange (Stack Overflow + Super User + Server Fault…)
  - DuckDuckGo Instant Answer
  - DuckDuckGo HTML (httpx, leve)
  - duckduckgo-search (pacote, último recurso)

Tudo com timeout global — nunca deve derrubar o /chat.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
from typing import Any
from urllib.parse import quote, quote_plus

import httpx

from .config import settings

logger = logging.getLogger(__name__)

SEARCH_TIMEOUT_SEC = float(
    os.getenv(
        "WEB_SEARCH_TIMEOUT",
        str(getattr(settings, "WEB_SEARCH_TIMEOUT", 12) or 12),
    )
)

_UA = (
    "Frequencia40-Gamma/0.7 "
    "(+https://github.com; assistant; research)"
)

_EXPLICIT = re.compile(
    r"\b("
    r"pesquisa(?:r)?|busc(?:a|ar)|google|na\s+internet|web\s*search|"
    r"procure|me\s+diga\s+sobre|atualize[-\s]?me|fontes?|"
    r"o\s+que\s+est[aá]\s+acontecendo|not[ií]cia|"
    r"pre[cç]o\s+(?:atual|hoje|agora)|cota[cç][aã]o|"
    r"hoje\s+(?:e|é)\s+dia|quem\s+ganhou|resultado\s+do\s+jogo|"
    r"vers[aã]o\s+mais\s+recente|lan[cç]amento\s+de|"
    r"documenta[cç][aã]o\s+(?:oficial|de)|"
    r"compare|diferen[cç]a\s+entre"
    r")\b",
    re.IGNORECASE,
)

_QUESTION = re.compile(
    r"^\s*(?:o\s+que|quem|quando|onde|qual|quais|como|por\s+que|porque|"
    r"what|who|when|where|which|how|why|is|are)\b",
    re.IGNORECASE,
)

_SKIP = re.compile(
    r"\b("
    r"lembre|mem[oó]ria|/memoria|escreva\s+um\s+c[oó]digo|refatore|"
    r"corrija\s+este|analise\s+este\s+arquivo|s[oó]\s+converse|"
    r"obrigado|valeu|ok\s*$|blz\s*$"
    r")\b",
    re.IGNORECASE,
)

_TECH = re.compile(
    r"\b("
    r"flutter|dart|python|fastapi|javascript|typescript|react|android|"
    r"ios|sql|docker|git|api|error|exception|stack\s*trace|npm|pub\.dev"
    r")\b",
    re.IGNORECASE,
)


def should_search(user_text: str) -> bool:
    text = (user_text or "").strip()
    if len(text) < 8:
        return False
    if _SKIP.search(text) and not _EXPLICIT.search(text):
        return False
    if _EXPLICIT.search(text):
        return True
    if _QUESTION.search(text) and len(text) < 320:
        return True
    # frases com “atual”, “hoje”, “2024/2025/2026”
    if re.search(r"\b(hoje|agora|atual(?:izado)?|202[4-9])\b", text, re.I):
        return True
    return False


def _clean_query(q: str) -> str:
    q = re.sub(r"\s+", " ", (q or "").strip())
    # remove pedidos meta que atrapalham o motor
    q = re.sub(
        r"^(?:por\s+favor|pesquisa(?:r)?|busc(?:a|ar)|me\s+diga|google)\s*[:,]?\s*",
        "",
        q,
        flags=re.I,
    )
    return q[:220].strip() or q[:220]


def _format_results(results: list[dict[str, str]], query: str) -> str:
    if not results:
        return (
            f"[Busca na web: nenhuma fonte útil para “{query}”. "
            "Responda com o conhecimento disponível e avise a limitação.]"
        )
    lines = [
        f"[Resultados de busca na web para: “{query}”]",
        "Use estas fontes. Não invente links. Cite os títulos quando fizer sentido.",
        "",
    ]
    for i, r in enumerate(results, 1):
        title = r.get("title") or "Sem título"
        url = r.get("url") or ""
        snippet = r.get("snippet") or ""
        src = r.get("source") or ""
        lines.append(f"{i}. {title}" + (f" ({src})" if src else ""))
        if url:
            lines.append(f"   URL: {url}")
        if snippet:
            lines.append(f"   {snippet}")
        lines.append("")
    return "\n".join(lines).strip()


def _dedupe(items: list[dict[str, str]], limit: int) -> list[dict[str, str]]:
    seen: set[str] = set()
    out: list[dict[str, str]] = []
    for it in items:
        url = (it.get("url") or "").strip().rstrip("/")
        key = url.lower() if url else (it.get("title") or "").lower()
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(it)
        if len(out) >= limit:
            break
    return out


async def search_web(query: str, *, max_results: int = 8) -> list[dict[str, str]]:
    query = _clean_query(query)
    if not query:
        return []
    max_results = max(3, min(max_results, 12))

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


async def search_and_format(query: str, *, max_results: int = 8) -> str:
    results = await search_web(query, max_results=max_results)
    return _format_results(results, query)


async def _search_pipeline(query: str, max_results: int) -> list[dict[str, str]]:
    """Dispara várias fontes em paralelo e mescla."""
    tasks = []

    # APIs com chave (prioridade de qualidade)
    if getattr(settings, "BRAVE_API_KEY", ""):
        tasks.append(_safe("brave", _search_brave(query, max_results)))
    if getattr(settings, "SERPER_API_KEY", ""):
        tasks.append(_safe("serper", _search_serper(query, max_results)))
    if getattr(settings, "TAVILY_API_KEY", ""):
        tasks.append(_safe("tavily", _search_tavily(query, max_results)))

    # Sempre (gratuitas / estáveis)
    tasks.append(_safe("wiki_pt", _search_wikipedia(query, max_results, lang="pt")))
    tasks.append(_safe("wiki_en", _search_wikipedia(query, max_results, lang="en")))
    tasks.append(_safe("wikidata", _search_wikidata(query, max_results)))
    tasks.append(_safe("ddg_instant", _search_ddg_instant(query, max_results)))
    tasks.append(_safe("ddg_html", _search_ddg_html(query, max_results)))

    if _TECH.search(query):
        tasks.append(_safe("stackexchange", _search_stackexchange(query, max_results)))

    # Pacote DDGS por último (pode falhar em cloud)
    tasks.append(_safe("ddgs", _search_ddgs(query, max_results)))

    results_lists = await asyncio.gather(*tasks)
    merged: list[dict[str, str]] = []
    for lst in results_lists:
        merged.extend(lst)

    # Preferir itens com URL http
    merged.sort(
        key=lambda x: (
            0 if (x.get("url") or "").startswith("http") else 1,
            0 if x.get("snippet") else 1,
        )
    )
    return _dedupe(merged, max_results)


async def _safe(name: str, coro) -> list[dict[str, str]]:
    try:
        return await asyncio.wait_for(coro, timeout=max(4.0, SEARCH_TIMEOUT_SEC - 2))
    except Exception as e:
        logger.debug("search source %s: %s", name, e)
        return []


# --------------------------------------------------------------------------- sources


async def _search_brave(query: str, max_results: int) -> list[dict[str, str]]:
    headers = {
        "Accept": "application/json",
        "X-Subscription-Token": settings.BRAVE_API_KEY,
        "User-Agent": _UA,
    }
    async with httpx.AsyncClient(timeout=7.0) as client:
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
                "source": "Brave",
            }
        )
    return out


async def _search_serper(query: str, max_results: int) -> list[dict[str, str]]:
    """Google via Serper.dev — SERPER_API_KEY."""
    key = settings.SERPER_API_KEY
    async with httpx.AsyncClient(timeout=7.0) as client:
        r = await client.post(
            "https://google.serper.dev/search",
            headers={
                "X-API-KEY": key,
                "Content-Type": "application/json",
                "User-Agent": _UA,
            },
            json={"q": query, "num": max_results},
        )
        r.raise_for_status()
        data = r.json()
    out = []
    for item in data.get("organic") or []:
        out.append(
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("link") or ""),
                "snippet": str(item.get("snippet") or ""),
                "source": "Google",
            }
        )
    return out


async def _search_tavily(query: str, max_results: int) -> list[dict[str, str]]:
    key = settings.TAVILY_API_KEY
    async with httpx.AsyncClient(timeout=8.0) as client:
        r = await client.post(
            "https://api.tavily.com/search",
            headers={"User-Agent": _UA},
            json={
                "api_key": key,
                "query": query,
                "max_results": max_results,
                "include_answer": False,
            },
        )
        r.raise_for_status()
        data = r.json()
    out = []
    for item in data.get("results") or []:
        out.append(
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("url") or ""),
                "snippet": str(item.get("content") or "")[:400],
                "source": "Tavily",
            }
        )
    return out


async def _search_wikipedia(
    query: str, max_results: int, *, lang: str
) -> list[dict[str, str]]:
    base = f"https://{lang}.wikipedia.org/w/api.php"
    params = {
        "action": "query",
        "list": "search",
        "srsearch": query,
        "srlimit": min(max_results, 8),
        "format": "json",
        "utf8": 1,
    }
    async with httpx.AsyncClient(timeout=6.0, headers={"User-Agent": _UA}) as client:
        r = await client.get(base, params=params)
        r.raise_for_status()
        data = r.json()

    out: list[dict[str, str]] = []
    for item in (data.get("query") or {}).get("search") or []:
        title = str(item.get("title") or "")
        snippet = re.sub(r"<[^>]+>", "", str(item.get("snippet") or ""))
        url = f"https://{lang}.wikipedia.org/wiki/{quote(title.replace(' ', '_'))}"
        out.append(
            {
                "title": title,
                "url": url,
                "snippet": snippet,
                "source": f"Wikipedia/{lang}",
            }
        )
    return out


async def _search_wikidata(query: str, max_results: int) -> list[dict[str, str]]:
    params = {
        "action": "wbsearchentities",
        "search": query,
        "language": "pt",
        "uselang": "pt",
        "limit": min(max_results, 6),
        "format": "json",
    }
    async with httpx.AsyncClient(timeout=6.0, headers={"User-Agent": _UA}) as client:
        r = await client.get("https://www.wikidata.org/w/api.php", params=params)
        r.raise_for_status()
        data = r.json()
    out = []
    for item in data.get("search") or []:
        qid = item.get("id") or ""
        out.append(
            {
                "title": str(item.get("label") or qid),
                "url": f"https://www.wikidata.org/wiki/{qid}" if qid else "",
                "snippet": str(item.get("description") or ""),
                "source": "Wikidata",
            }
        )
    return out


async def _search_stackexchange(query: str, max_results: int) -> list[dict[str, str]]:
    """API pública Stack Exchange (sem chave, com throttle)."""
    params = {
        "order": "desc",
        "sort": "relevance",
        "q": query,
        "site": "stackoverflow",
        "pagesize": min(max_results, 5),
        "filter": "default",
    }
    async with httpx.AsyncClient(timeout=7.0, headers={"User-Agent": _UA}) as client:
        r = await client.get(
            "https://api.stackexchange.com/2.3/search/advanced",
            params=params,
        )
        r.raise_for_status()
        data = r.json()
    out = []
    for item in data.get("items") or []:
        out.append(
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("link") or ""),
                "snippet": f"Score {item.get('score', 0)} · "
                f"respostas: {item.get('answer_count', 0)}",
                "source": "StackOverflow",
            }
        )
    return out


async def _search_ddg_instant(query: str, max_results: int) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=6.0, headers={"User-Agent": _UA}) as client:
        r = await client.get(
            "https://api.duckduckgo.com/",
            params={"q": query, "format": "json", "no_html": 1, "skip_disambig": 1},
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
                "source": "DuckDuckGo",
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
                    "source": "DuckDuckGo",
                }
            )
    return out[:max_results]


async def _search_ddg_html(query: str, max_results: int) -> list[dict[str, str]]:
    """HTML lite do DDG — melhor que nada quando a API falha."""
    url = "https://html.duckduckgo.com/html/"
    async with httpx.AsyncClient(
        timeout=7.0,
        headers={"User-Agent": _UA},
        follow_redirects=True,
    ) as client:
        r = await client.post(url, data={"q": query})
        r.raise_for_status()
        html = r.text

    out: list[dict[str, str]] = []
    # result links
    for m in re.finditer(
        r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        html,
        re.I | re.S,
    ):
        href = m.group(1)
        title = re.sub(r"<[^>]+>", "", m.group(2)).strip()
        # DDG redirect URLs — tenta extrair uddg=
        real = href
        um = re.search(r"uddg=([^&]+)", href)
        if um:
            from urllib.parse import unquote

            real = unquote(um.group(1))
        out.append(
            {
                "title": title or real,
                "url": real,
                "snippet": "",
                "source": "DuckDuckGo",
            }
        )
        if len(out) >= max_results:
            break

    # snippets
    snippets = re.findall(r'class="result__snippet"[^>]*>(.*?)</(?:a|td|div)', html, re.I | re.S)
    for i, sn in enumerate(snippets):
        if i < len(out):
            out[i]["snippet"] = re.sub(r"<[^>]+>", "", sn).strip()[:300]
    return out


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
                        "source": "DuckDuckGo",
                    }
                )
        return out

    return await asyncio.to_thread(_run)
