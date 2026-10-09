"""GitHub Reader — prioriza raw/jsDelivr (sem rate limit da API) + API com token."""

from __future__ import annotations

import base64
import logging
import os
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)

GITHUB_API = "https://api.github.com"
DEFAULT_TIMEOUT = 30.0

# Prefixo comuns em projetos Flutter / Python / Node — usados quando a tree API falha
_COMMON_PREFIXES = (
    "",
    "lib/",
    "lib/services/",
    "lib/screens/",
    "lib/widgets/",
    "lib/core/",
    "lib/models/",
    "lib/utils/",
    "backend/",
    "backend/app/",
    "backend/app/core/",
    "backend/app/routes/",
    "backend/app/core/code_analyzer/",
    "src/",
    "src/main/",
    "app/",
    "test/",
    "tests/",
)


def _headers() -> dict[str, str]:
    h = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Gama-CodeAnalyzer/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = (os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or "").strip()
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def has_github_token() -> bool:
    return bool((os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or "").strip())


async def get_repo_default_branch(owner: str, repo: str) -> str:
    url = f"{GITHUB_API}/repos/{owner}/{repo}"
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        r = await client.get(url)
        if r.status_code == 404:
            raise ValueError(f"Repositório não encontrado: {owner}/{repo}")
        if r.status_code == 403:
            logger.warning("get_repo_default_branch 403 — assumindo main")
            return "main"
        r.raise_for_status()
        data = r.json()
        return data.get("default_branch") or "main"


async def get_tree(
    owner: str, repo: str, branch: str = "main"
) -> tuple[str, list[dict[str, Any]]]:
    """Retorna (tree_sha, lista de {path, sha, size, type}).

    Em 403 rate limit, levanta httpx.HTTPStatusError para o caller fazer fallback.
    """
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        ref_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/ref/heads/{branch}"
        r = await client.get(ref_url)
        if r.status_code == 404:
            branch = await get_repo_default_branch(owner, repo)
            ref_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/ref/heads/{branch}"
            r = await client.get(ref_url)
        r.raise_for_status()
        commit_sha = r.json()["object"]["sha"]

        commit_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/commits/{commit_sha}"
        rc = await client.get(commit_url)
        rc.raise_for_status()
        tree_sha = rc.json()["tree"]["sha"]

        tree_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/trees/{tree_sha}?recursive=1"
        rt = await client.get(tree_url)
        rt.raise_for_status()
        tree = rt.json()
        entries = []
        for item in tree.get("tree") or []:
            if item.get("type") != "blob":
                continue
            entries.append(
                {
                    "path": item["path"],
                    "sha": item["sha"],
                    "size": item.get("size") or 0,
                    "type": "blob",
                }
            )
        return tree_sha, entries


async def fetch_raw_content(
    owner: str, repo: str, path: str, *, ref: str = "main"
) -> str:
    """Baixa arquivo público sem usar a API (não consome rate limit de 60/h).

    Ordem: raw.githubusercontent.com → jsDelivr → Contents API (se token).
    """
    path = (path or "").lstrip("/")
    if not path:
        return ""

    urls = [
        f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}",
        f"https://cdn.jsdelivr.net/gh/{owner}/{repo}@{ref}/{path}",
    ]

    async with httpx.AsyncClient(
        timeout=DEFAULT_TIMEOUT,
        headers={"User-Agent": "Gama-CodeAnalyzer/1.0"},
        follow_redirects=True,
    ) as client:
        for url in urls:
            try:
                r = await client.get(url)
                if r.status_code == 200 and r.text and len(r.text) > 0:
                    # jsDelivr às vezes devolve HTML de erro
                    if r.text.lstrip().lower().startswith("<!"):
                        continue
                    return r.text
            except Exception as e:
                logger.debug("raw fetch %s: %s", url, e)

    # Último recurso: API (só útil com token ou fora do rate limit)
    return await fetch_file_content_api(owner, repo, path, ref=ref)


async def fetch_file_content_api(
    owner: str, repo: str, path: str, *, ref: str = "main"
) -> str:
    """Contents API (conta no rate limit)."""
    url = f"{GITHUB_API}/repos/{owner}/{repo}/contents/{path}"
    params = {"ref": ref}
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        r = await client.get(url, params=params)
        if r.status_code in (404, 403):
            return ""
        if r.status_code != 200:
            return ""
        data = r.json()
        if isinstance(data, list):
            return ""
        content = data.get("content") or ""
        encoding = data.get("encoding") or "base64"
        if encoding == "base64":
            try:
                return base64.b64decode(content).decode("utf-8", errors="replace")
            except Exception:
                return ""
        return str(content)


# Compat: nome antigo usado pelo pipeline
async def fetch_file_content(
    owner: str, repo: str, path: str, *, ref: str = "main"
) -> str:
    return await fetch_raw_content(owner, repo, path, ref=ref)


async def fetch_blob(owner: str, repo: str, sha: str) -> str:
    url = f"{GITHUB_API}/repos/{owner}/{repo}/git/blobs/{sha}"
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        r = await client.get(url)
        if r.status_code != 200:
            return ""
        data = r.json()
        content = data.get("content") or ""
        if data.get("encoding") == "base64":
            try:
                return base64.b64decode(content).decode("utf-8", errors="replace")
            except Exception:
                return ""
        return str(content)


async def fetch_file_with_path_guess(
    owner: str,
    repo: str,
    name_or_path: str,
    *,
    ref: str = "main",
    known_paths: Optional[list[str]] = None,
) -> tuple[str, str]:
    """Tenta achar o arquivo. Retorna (path_real, content) ou ("", "")."""
    name_or_path = (name_or_path or "").strip().lstrip("./")
    if not name_or_path:
        return "", ""

    candidates: list[str] = []
    if known_paths:
        for p in known_paths:
            if p == name_or_path or p.endswith("/" + name_or_path) or p.endswith(name_or_path):
                candidates.append(p)
            elif p.lower().endswith("/" + name_or_path.lower()) or p.lower().endswith(
                name_or_path.lower()
            ):
                candidates.append(p)

    # path já completo
    if "/" in name_or_path:
        candidates.insert(0, name_or_path)
    else:
        for prefix in _COMMON_PREFIXES:
            candidates.append(f"{prefix}{name_or_path}")

    # dedupe
    seen: set[str] = set()
    ordered: list[str] = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            ordered.append(c)

    for path in ordered[:40]:
        text = await fetch_raw_content(owner, repo, path, ref=ref)
        if text:
            return path, text
    return "", ""
