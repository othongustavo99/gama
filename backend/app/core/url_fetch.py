"""Fetch simples de URLs enviadas pelo usuário para a Gamma analisar."""

from __future__ import annotations

import logging
import re
from typing import List, Tuple
from urllib.parse import urlparse

import httpx

logger = logging.getLogger(__name__)

_URL_RE = re.compile(r"https?://[^\s\)\]\>\"']+", re.I)

def extract_urls(text: str, limit: int = 3) -> List[str]:
    if not text:
        return []
    found = []
    for m in _URL_RE.finditer(text):
        url = m.group(0).rstrip(".,;:!?")
        if url not in found:
            found.append(url)
        if len(found) >= limit:
            break
    return found


async def fetch_url_text(url: str, *, max_chars: int = 12000) -> Tuple[str, str]:
    """Retorna (title, text)."""
    headers = {
        "User-Agent": "Frequencia40-Gamma/1.0 (+assistant; link-reader)",
        "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8",
    }
    try:
        async with httpx.AsyncClient(
            timeout=12.0, follow_redirects=True, headers=headers
        ) as client:
            r = await client.get(url)
            r.raise_for_status()
            ctype = (r.headers.get("content-type") or "").lower()
            raw = r.text if "text" in ctype or "json" in ctype or not ctype else ""
            if not raw:
                raw = r.content.decode("utf-8", errors="replace")
    except Exception as e:
        logger.warning("url fetch failed %s: %s", url, e)
        return url, f"(não foi possível abrir o link: {e})"

    title = ""
    tm = re.search(r"<title[^>]*>(.*?)</title>", raw, re.I | re.S)
    if tm:
        title = re.sub(r"\s+", " ", tm.group(1)).strip()

    # strip scripts/styles
    text = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", raw)
    text = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", text)
    text = re.sub(r"(?is)<!--.*?-->", " ", text)
    text = re.sub(r"(?is)<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > max_chars:
        text = text[:max_chars] + " …"
    return title or urlparse(url).netloc, text or "(página sem texto legível)"


async def build_url_context(user_text: str) -> str:
    urls = extract_urls(user_text)
    if not urls:
        return ""
    blocks = ["[Conteúdo de links enviados pelo usuário]"]
    for url in urls:
        title, body = await fetch_url_text(url)
        blocks.append(f"### Link: {url}\nTítulo: {title}\n{body}")
    blocks.append(
        "Use o conteúdo acima para responder. Se o link falhou, diga isso."
    )
    return "\n\n".join(blocks)
