"""Fetch de URLs do usuário — GitHub e páginas genéricas."""

from __future__ import annotations

import logging
import re
from typing import List, Tuple
from urllib.parse import urlparse

import httpx

logger = logging.getLogger(__name__)

_URL_RE = re.compile(r"https?://[^\s\)\]\>\"']+", re.I)

# github.com/owner/repo/blob/branch/path -> raw
_GH_BLOB = re.compile(
    r"^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$",
    re.I,
)
_GH_TREE = re.compile(
    r"^https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/?(.*)$",
    re.I,
)
_GH_REPO = re.compile(
    r"^https?://github\.com/([^/]+)/([^/]+)/?$",
    re.I,
)
_GH_RAW = re.compile(r"^https?://raw\.githubusercontent\.com/", re.I)


def extract_urls(text: str) -> List[str]:
    found = []
    for m in _URL_RE.finditer(text or ""):
        u = m.group(0).rstrip(".,;:!?")
        if u not in found:
            found.append(u)
    return found[:5]


def _github_to_fetch_urls(url: str) -> List[str]:
    """Converte links do GitHub em URLs de conteúdo legível."""
    m = _GH_BLOB.match(url)
    if m:
        owner, repo, branch, path = m.groups()
        return [f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}"]

    m = _GH_TREE.match(url)
    if m:
        owner, repo, branch, path = m.groups()
        path = path.strip("/")
        # API contents
        api = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}?ref={branch}"
        return [api]

    m = _GH_REPO.match(url)
    if m:
        owner, repo = m.groups()
        return [
            f"https://raw.githubusercontent.com/{owner}/{repo}/main/README.md",
            f"https://raw.githubusercontent.com/{owner}/{repo}/master/README.md",
            f"https://api.github.com/repos/{owner}/{repo}",
        ]

    if _GH_RAW.match(url):
        return [url]

    return [url]


async def fetch_url_text(url: str, max_chars: int = 24_000) -> Tuple[str, str]:
    targets = _github_to_fetch_urls(url)
    last_err = ""
    headers = {
        "User-Agent": "Frequencia40-Gamma/1.0 (+assistant; research)",
        "Accept": "application/vnd.github.v3+json, text/plain, text/html, */*",
    }

    async with httpx.AsyncClient(
        timeout=18.0, follow_redirects=True, headers=headers
    ) as client:
        for target in targets:
            try:
                r = await client.get(target)
                if r.status_code >= 400:
                    last_err = f"HTTP {r.status_code}"
                    continue
                ctype = (r.headers.get("content-type") or "").lower()

                # JSON da API GitHub (arquivo ou diretório)
                if "application/json" in ctype:
                    data = r.json()
                    if isinstance(data, dict) and data.get("type") == "file":
                        import base64

                        if data.get("encoding") == "base64" and data.get("content"):
                            raw = base64.b64decode(data["content"]).decode(
                                "utf-8", errors="replace"
                            )
                        else:
                            raw = str(data.get("content") or data)
                        name = data.get("path") or data.get("name") or target
                        if len(raw) > max_chars:
                            raw = raw[:max_chars] + " …"
                        return name, raw
                    if isinstance(data, list):
                        # diretório
                        lines = [f"Conteúdo do diretório ({url}):"]
                        for item in data[:80]:
                            if isinstance(item, dict):
                                lines.append(
                                    f"- {item.get('type', '?')}: {item.get('path') or item.get('name')}"
                                )
                        return urlparse(url).path or url, "\n".join(lines)
                    if isinstance(data, dict) and "full_name" in data:
                        desc = data.get("description") or ""
                        return data.get("full_name", url), (
                            f"Repositório: {data.get('full_name')}\n"
                            f"Descrição: {desc}\n"
                            f"Linguagem: {data.get('language')}\n"
                            f"Stars: {data.get('stargazers_count')}\n"
                            f"URL: {data.get('html_url')}"
                        )
                    raw = str(data)
                else:
                    raw = r.text if r.text else r.content.decode("utf-8", errors="replace")

                title = ""
                tm = re.search(r"<title[^>]*>(.*?)</title>", raw, re.I | re.S)
                if tm:
                    title = re.sub(r"\s+", " ", tm.group(1)).strip()

                # HTML → texto
                if "html" in ctype or raw.lstrip().lower().startswith("<!doctype") or "<html" in raw[:200].lower():
                    text = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", raw)
                    text = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", text)
                    text = re.sub(r"(?is)<!--.*?-->", " ", text)
                    text = re.sub(r"(?is)<[^>]+>", " ", text)
                    text = re.sub(r"\s+", " ", text).strip()
                else:
                    # código / markdown / plain
                    text = raw

                if len(text) > max_chars:
                    text = text[:max_chars] + " …"
                return title or urlparse(url).path or url, text or "(sem conteúdo)"
            except Exception as e:
                last_err = str(e)
                logger.warning("url fetch failed %s: %s", target, e)
                continue

    return url, f"(não foi possível abrir o link: {last_err})"


async def build_url_context(user_text: str) -> str:
    urls = extract_urls(user_text)
    if not urls:
        return ""
    blocks = [
        "[Conteúdo de links enviados pelo usuário]",
        "Se for código (GitHub/raw), analise o código em detalhe.",
    ]
    for url in urls:
        title, body = await fetch_url_text(url)
        blocks.append(f"### Link: {url}\nTítulo/arquivo: {title}\n{body}")
    blocks.append(
        "Use o conteúdo acima para responder. Se o link falhou, diga isso claramente."
    )
    return "\n\n".join(blocks)
