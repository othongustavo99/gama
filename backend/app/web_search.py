"""
Busca web com ativação contextual e sanitização de consultas.

Modos (env WEB_SEARCH_MODE):
  off         → desativa toda busca, inclusive pedidos explícitos
  balanced    → perguntas/fatos atuais e tópicos técnicos (padrão)
  explicit    → só pesquisa quando o usuário pedir diretamente
  aggressive  → busca em mensagens substantivas; não recomendado para privacidade

Antes de sair do backend, a consulta é sanitizada para remover blocos de código,
credenciais e dados pessoais comuns. Isso reduz a exposição acidental, mas não
substitui a avaliação do usuário antes de enviar assuntos privados a serviços externos.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
from typing import Any
from urllib.parse import quote

import httpx

from .config import settings
from .core.search_privacy import sanitize_search_query

logger = logging.getLogger(__name__)

SEARCH_TIMEOUT_SEC = float(
    os.getenv(
        "WEB_SEARCH_TIMEOUT",
        str(getattr(settings, "WEB_SEARCH_TIMEOUT", 12) or 12),
    )
)

SEARCH_MODE = (
    os.getenv("WEB_SEARCH_MODE", getattr(settings, "WEB_SEARCH_MODE", "balanced") or "balanced")
    .strip()
    .lower()
)

_UA = "Frequencia40-Gamma/0.8 (+assistant; research)"

_EXPLICIT = re.compile(
    r"\b("
    r"pesquisa(?:r)?|busc(?:a|ar)|google|na\s+internet|web\s*search|"
    r"procure|atualize[-\s]?me|com\s+fontes|"
    r"o\s+que\s+est[aá]\s+acontecendo|not[ií]cia|"
    r"pre[cç]o\s+(?:atual|hoje|agora)|cota[cç][aã]o|"
    r"vers[aã]o\s+mais\s+recente|lan[cç]amento"
    r")\b",
    re.IGNORECASE,
)

_FACTUAL = re.compile(
    r"\b("
    r"o\s+que\s+[ée]|quem\s+[ée]|quando\s+|onde\s+|qual\s+|quais\s+|"
    r"como\s+(?:funciona|fazer|usar|configurar|instalar)|"
    r"por\s+que|porque|diferen[cç]a|compare|melhor\s+|"
    r"significa|defini[cç][aã]o|hist[oó]ria\s+d|"
    r"what\s+is|who\s+is|how\s+to|why\s+"
    r")\b",
    re.IGNORECASE,
)

_SKIP = re.compile(
    r"(?:"
    r"^\s*(?:oi|ol[aá]|hey|eae|fala|bom\s+dia|boa\s+tarde|boa\s+noite|teste|test)\s*[!.?]*\s*$|"
    r"^\s*(?:obrigad[oa]|valeu|thanks|ok|blz|beleza|entendi|certo|sim|não|nao)\s*[!.?]*\s*$|"
    r"^\s*/(?:memoria|memory|help|ajuda)\b|"
    r"\blembre(?:\s+que)?\b|"
    r"\b(?:s[oó]\s+converse|n[aã]o\s+pesquise|sem\s+busca|offline)\b|"
    r"\b(?:refatore|corrija|explique\s+(?:este|esse)\s+c[oó]digo)\b"
    r")",
    re.IGNORECASE,
)

# Código puro / refatoração local — não precisa web
_CODE_ONLY = re.compile(
    r"(?:"
    r"```|"
    r"^\s*(?:refatore|corrija|complete|implemente)\s+(?:este|esse|o)\s+(?:c[oó]digo|trecho)|"
    r"erro\s+no\s+meu\s+c[oó]digo|"
    r"analise\s+este\s+arquivo"
    r")",
    re.IGNORECASE | re.MULTILINE,
)


def should_search(user_text: str) -> bool:
    text = (user_text or "").strip()
    if len(text) < 12:
        return False

    # A desativação global tem precedência sobre intenção explícita ou heurísticas.
    if not getattr(settings, "WEB_SEARCH_ENABLED", True):
        return False
    mode = SEARCH_MODE
    if mode in ("off", "0", "false", "disabled", "none"):
        return False

    if _SKIP.search(text):
        return False

    if _EXPLICIT.search(text):
        return True

    if mode in ("explicit", "manual"):
        return False

    # Código/arquivos privados são analisados localmente; a busca só é útil se
    # houver pedido claro de documentação, versão ou erro público.
    if _CODE_ONLY.search(text) and not _EXPLICIT.search(text):
        if not re.search(r"\b(documenta[cç][aã]o|stackoverflow|pub\.dev|erro\s+oficial)\b", text, re.I):
            return False

    if mode in ("aggressive", "always", "max"):
        return len(text) >= 12

    # balanced: mantém a heurística histórica sem enviar automaticamente toda mensagem.
    if _FACTUAL.search(text):
        return True
    if re.search(r"\b(hoje|agora|atual(?:izado)?|202[4-9]|not[ií]cia)\b", text, re.I):
        return True
    if re.search(
        r"\b(flutter|dart|python|fastapi|android|ios|docker|api|sdk)\b",
        text,
        re.I,
    ) and len(text) > 20:
        return True
    return False


def web_tools_enabled_for_turn(user_text: str) -> bool:
    """Define se o agente pode sequer receber as ferramentas de busca neste turno.

    No modo `explicit`, não basta bloquear o HTTP ao final: ocultamos as ferramentas
    quando a solicitação não pede pesquisa diretamente, evitando chamadas inúteis e
    deixando a política de privacidade coerente com a configuração escolhida.
    """
    if not getattr(settings, "WEB_SEARCH_ENABLED", True):
        return False
    if SEARCH_MODE in ("off", "0", "false", "disabled", "none"):
        return False
    text = (user_text or "").strip()
    if _SKIP.search(text):
        return False
    if SEARCH_MODE in ("explicit", "manual"):
        return bool(_EXPLICIT.search(text))
    return True


def _clean_query(q: str) -> str:
    # Nunca enviar o texto bruto. Este filtro é chamado centralmente por todos os
    # caminhos (heurística, tools do agente e endpoint de busca).
    sanitized = sanitize_search_query(q, max_chars=220)
    sanitized = re.sub(
        r"^(?:por\s+favor|pesquisa(?:r)?|busc(?:a|ar)|me\s+diga|google)\s*[:,]?\s*",
        "",
        sanitized,
        flags=re.I,
    )
    sanitized = re.sub(r"\s+", " ", sanitized).strip()
    return sanitized[:220]


def _format_results(results: list[dict[str, str]], query: str) -> str:
    if not results:
        return (
            f"[Busca na web: nenhuma fonte útil para “{query}”. "
            "Responda com o melhor conhecimento disponível, deixe clara a incerteza "
            "e ofereça o que for mais útil mesmo assim.]"
        )
    lines = [
        f"[Resultados de busca na web para: “{query}”]",
        "Instruções: use estas fontes para enriquecer a resposta. "
        "Seja completo, prático e honesto. Não invente links. "
        "Incorpore os dados relevantes no texto (não precisa listar 'Fontes:' no final).",
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
    # Camada central de proteção: chamadas diretas/agent/routes também respeitam
    # o interruptor global, independentemente da heurística `should_search`.
    if not getattr(settings, "WEB_SEARCH_ENABLED", True):
        return []
    if SEARCH_MODE in ("off", "0", "false", "disabled", "none"):
        return []
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
        # Não registrar a consulta: mesmo sanitizada, ela pode conter contexto privado.
        logger.warning("web search timeout (%.1fs)", SEARCH_TIMEOUT_SEC)
        return []
    except Exception as e:
        logger.warning("web search error (%s)", type(e).__name__)
        return []


async def search_and_format(query: str, *, max_results: int = 8) -> str:
    safe_query = _clean_query(query)
    results = await search_web(safe_query, max_results=max_results)
    return _format_results(results, safe_query)


async def _search_pipeline(query: str, max_results: int) -> list[dict[str, str]]:
    tasks = []

    if getattr(settings, "BRAVE_API_KEY", ""):
        tasks.append(_safe("brave", _search_brave(query, max_results)))
    if getattr(settings, "SERPER_API_KEY", ""):
        tasks.append(_safe("serper", _search_serper(query, max_results)))
    if getattr(settings, "TAVILY_API_KEY", ""):
        tasks.append(_safe("tavily", _search_tavily(query, max_results)))

    tasks.append(_safe("wiki_pt", _search_wikipedia(query, max_results, lang="pt")))
    tasks.append(_safe("wiki_en", _search_wikipedia(query, max_results, lang="en")))
    tasks.append(_safe("wikidata", _search_wikidata(query, max_results)))
    tasks.append(_safe("ddg_instant", _search_ddg_instant(query, max_results)))
    tasks.append(_safe("ddg_html", _search_ddg_html(query, max_results)))

    if re.search(
        r"\b(flutter|dart|python|code|error|api|sdk|android|ios|javascript)\b",
        query,
        re.I,
    ):
        tasks.append(_safe("stackexchange", _search_stackexchange(query, max_results)))

    tasks.append(_safe("ddgs", _search_ddgs(query, max_results)))

    results_lists = await asyncio.gather(*tasks)
    merged: list[dict[str, str]] = []
    for lst in results_lists:
        merged.extend(lst)

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
        # Exceções HTTP podem incluir a URL consultada; não registrar query/corpo.
        logger.debug("search source %s failed (%s)", name, type(e).__name__)
        return []


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
                "snippet": f"Score {item.get('score', 0)} · respostas: {item.get('answer_count', 0)}",
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
    for m in re.finditer(
        r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        html,
        re.I | re.S,
    ):
        href = m.group(1)
        title = re.sub(r"<[^>]+>", "", m.group(2)).strip()
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

    snippets = re.findall(
        r'class="result__snippet"[^>]*>(.*?)</(?:a|td|div)', html, re.I | re.S
    )
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
