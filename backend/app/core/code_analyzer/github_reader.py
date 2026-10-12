"""GitHub Reader — prioriza raw/jsDelivr (sem rate limit da API) + API com token."""

from __future__ import annotations

import base64
import logging
import os
import re
from typing import Any, Optional
from urllib.parse import quote

import httpx

logger = logging.getLogger(__name__)

GITHUB_API = "https://api.github.com"
DEFAULT_TIMEOUT = 30.0
MAX_TREE_ENTRIES = 25_000  # proteção contra repos gigantes
MAX_TEXT_FILE_BYTES = 8_000_000

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
        if r.status_code in (403, 429):
            r.raise_for_status()
        r.raise_for_status()
        data = r.json()
        return data.get("default_branch") or "main"


async def get_tree_full(
    owner: str, repo: str, branch: str = "main"
) -> tuple[str, list[dict[str, Any]], str, bool, str]:
    """Retorna (tree_sha, blobs, ref resolvido, árvore parcial, commit_sha).

    O commit_sha é o SHA imutável usado para materializar exatamente esta versão.

    Resolve o default branch quando ``main`` não existe. Se a árvore recursiva
    vier truncada, percorre subárvores individualmente até o limite local.
    """
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        resolved_ref = (branch or "main").strip()
        object_type = "commit"
        if re.fullmatch(r"[a-fA-F0-9]{7,40}", resolved_ref):
            commit_sha = resolved_ref
        else:
            ref_url = (
                f"{GITHUB_API}/repos/{owner}/{repo}/git/ref/heads/"
                f"{quote(resolved_ref, safe='')}"
            )
            r = await client.get(ref_url)
            if r.status_code == 404:
                # An unqualified /tree/main URL should follow the actual default
                # branch (many established repositories still use master).
                if resolved_ref == "main":
                    resolved_ref = await get_repo_default_branch(owner, repo)
                    ref_url = (
                        f"{GITHUB_API}/repos/{owner}/{repo}/git/ref/heads/"
                        f"{quote(resolved_ref, safe='')}"
                    )
                    r = await client.get(ref_url)
                else:
                    # GitHub tree URLs can point to tags as well as branches.
                    tag_url = (
                        f"{GITHUB_API}/repos/{owner}/{repo}/git/ref/tags/"
                        f"{quote(resolved_ref, safe='')}"
                    )
                    tag_response = await client.get(tag_url)
                    if tag_response.status_code == 200:
                        r = tag_response
                    else:
                        raise ValueError(
                            f"Branch ou tag '{resolved_ref}' não encontrada em {owner}/{repo}"
                        )
            r.raise_for_status()
            commit_sha = str((r.json().get("object") or {}).get("sha") or "")
            object_type = str((r.json().get("object") or {}).get("type") or "")
            if not commit_sha:
                raise ValueError(f"Não foi possível resolver a referência '{resolved_ref}'")
            # Annotated tags point to a tag object, which in turn points to a
            # commit (or another tag). Peel a bounded chain before requesting
            # the commit endpoint.
            for _ in range(4):
                if object_type != "tag":
                    break
                tag_object = await client.get(
                    f"{GITHUB_API}/repos/{owner}/{repo}/git/tags/{quote(commit_sha, safe='')}"
                )
                tag_object.raise_for_status()
                target = tag_object.json().get("object") or {}
                commit_sha = str(target.get("sha") or "")
                object_type = str(target.get("type") or "")
                if not commit_sha:
                    raise ValueError(f"Não foi possível resolver a tag '{resolved_ref}'")
            if object_type == "tag":
                raise ValueError(f"A tag '{resolved_ref}' excedeu o limite de referências aninhadas")

        commit_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/commits/{quote(commit_sha, safe='')}"
        rc = await client.get(commit_url)
        rc.raise_for_status()
        tree_sha = str((rc.json().get("tree") or {}).get("sha") or "")
        if not tree_sha:
            raise ValueError(f"Não foi possível ler a árvore de {owner}/{repo}@{resolved_ref}")

        tree_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/trees/{tree_sha}"
        rt = await client.get(tree_url, params={"recursive": "1"})
        rt.raise_for_status()
        tree = rt.json()
        tree_items = tree.get("tree") or []
        partial = bool(tree.get("truncated")) or len(tree_items) > MAX_TREE_ENTRIES

        def _blob(item: dict[str, Any], prefix: str = "") -> dict[str, Any]:
            return {
                "path": f"{prefix}{item['path']}",
                "sha": item.get("sha"),
                "size": item.get("size") or 0,
                "type": "blob",
            }

        if not tree.get("truncated"):
            entries = [
                _blob(item)
                for item in tree_items[:MAX_TREE_ENTRIES]
                if item.get("type") == "blob"
            ]
            return tree_sha, entries, resolved_ref, partial, commit_sha

        # The recursive endpoint may omit entries. Walk each directory tree
        # without recursion so large repositories are not silently mis-indexed.
        entries: list[dict[str, Any]] = []
        pending: list[tuple[str, str]] = [("", tree_sha)]
        while pending and len(entries) < MAX_TREE_ENTRIES:
            prefix, subtree_sha = pending.pop()
            subtree_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/trees/{subtree_sha}"
            response = await client.get(subtree_url)
            response.raise_for_status()
            subtree = response.json()
            for item in subtree.get("tree") or []:
                path = f"{prefix}{item.get('path') or ''}"
                if item.get("type") == "tree":
                    pending.append((f"{path}/", str(item.get("sha") or "")))
                elif item.get("type") == "blob":
                    if len(entries) >= MAX_TREE_ENTRIES:
                        partial = True
                        break
                    entries.append(_blob(item, prefix))
            if subtree.get("truncated"):
                partial = True
        if pending:
            partial = True
        return tree_sha, entries, resolved_ref, partial, commit_sha


async def get_tree(
    owner: str, repo: str, branch: str = "main"
) -> tuple[str, list[dict[str, Any]], str, bool]:
    """Compatibilidade: mesma assinatura de antes, sem o commit_sha."""
    tree_sha, entries, resolved_ref, partial, _ = await get_tree_full(owner, repo, branch)
    return tree_sha, entries, resolved_ref, partial


async def fetch_raw_content(
    owner: str, repo: str, path: str, *, ref: str = "main"
) -> str:
    """Baixa arquivo público sem usar a API (não consome rate limit de 60/h).

    Ordem: raw.githubusercontent.com → jsDelivr → Contents API (se token).
    """
    path = (path or "").lstrip("/")
    if not path:
        return ""

    refs = [ref]
    if ref == "main":
        refs.append("master")
    encoded_path = "/".join(quote(part, safe="") for part in path.split("/"))
    urls = [
        url
        for candidate_ref in refs
        for url in (
            f"https://raw.githubusercontent.com/{owner}/{repo}/{candidate_ref}/{encoded_path}",
            f"https://cdn.jsdelivr.net/gh/{owner}/{repo}@{candidate_ref}/{encoded_path}",
        )
    ]

    rate_limited = False
    async with httpx.AsyncClient(
        timeout=DEFAULT_TIMEOUT,
        headers={"User-Agent": "Gama-CodeAnalyzer/1.0"},
        follow_redirects=True,
    ) as client:
        for url in urls:
            try:
                async with client.stream("GET", url) as response:
                    if response.status_code in (403, 429):
                        rate_limited = True
                    if response.status_code != 200:
                        continue
                    content_length = int(response.headers.get("content-length") or 0)
                    if content_length > MAX_TEXT_FILE_BYTES:
                        continue
                    content = bytearray()
                    oversized = False
                    async for chunk in response.aiter_bytes():
                        content.extend(chunk)
                        if len(content) > MAX_TEXT_FILE_BYTES:
                            oversized = True
                            break
                    if not content or oversized or b"\x00" in content[:8192]:
                        continue
                    text = bytes(content).decode("utf-8", errors="replace")
                    # jsDelivr às vezes devolve HTML de erro
                    if text.lstrip().lower().startswith("<!") or text.startswith(
                        "Couldn't find the requested release version"
                    ):
                        continue
                    return text
            except Exception as e:
                logger.debug("raw fetch %s: %s", url, e)

    # 404 em raw/jsDelivr significa "arquivo não existe": não gastar a cota
    # da API (60 req/h sem token) em cada candidato de path. A API só entra
    # como fallback quando há token ou quando o raw/jsDelivr deu rate limit.
    if not (has_github_token() or rate_limited):
        return ""
    return await fetch_file_content_api(owner, repo, path, ref=ref)


async def fetch_raw_bytes(
    owner: str,
    repo: str,
    path: str,
    *,
    ref: str = "main",
    max_bytes: int = MAX_TEXT_FILE_BYTES,
) -> Optional[bytes]:
    """Baixa o conteúdo bruto (inclusive binário) de um arquivo. None se indisponível."""
    path = (path or "").lstrip("/")
    if not path:
        return None
    refs = [ref] + (["master"] if ref == "main" else [])
    encoded_path = "/".join(quote(part, safe="") for part in path.split("/"))
    async with httpx.AsyncClient(
        timeout=DEFAULT_TIMEOUT,
        headers={"User-Agent": "Gama-CodeAnalyzer/1.0"},
        follow_redirects=True,
    ) as client:
        for candidate_ref in refs:
            for url in (
                f"https://raw.githubusercontent.com/{owner}/{repo}/{candidate_ref}/{encoded_path}",
                f"https://cdn.jsdelivr.net/gh/{owner}/{repo}@{candidate_ref}/{encoded_path}",
            ):
                try:
                    async with client.stream("GET", url) as response:
                        if response.status_code != 200:
                            continue
                        declared = int(response.headers.get("content-length") or 0)
                        if declared > max_bytes:
                            return None
                        buf = bytearray()
                        async for chunk in response.aiter_bytes():
                            buf.extend(chunk)
                            if len(buf) > max_bytes:
                                return None
                        return bytes(buf)
                except Exception as e:
                    logger.debug("raw bytes %s: %s", url, e)
    return None


async def fetch_file_content_api(
    owner: str, repo: str, path: str, *, ref: str = "main"
) -> str:
    """Contents API (conta no rate limit)."""
    encoded_path = "/".join(quote(part, safe="") for part in path.lstrip("/").split("/"))
    url = f"{GITHUB_API}/repos/{owner}/{repo}/contents/{encoded_path}"
    params = {"ref": ref}
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        r = await client.get(url, params=params)
        if r.status_code in (404, 403, 429):
            return ""
        if r.status_code != 200:
            return ""
        if int(r.headers.get("content-length") or 0) > MAX_TEXT_FILE_BYTES:
            return ""
        data = r.json()
        if isinstance(data, list):
            return ""
        content = data.get("content") or ""
        encoding = data.get("encoding") or "base64"
        if encoding == "base64":
            try:
                decoded = base64.b64decode(content)
                if len(decoded) > MAX_TEXT_FILE_BYTES or b"\x00" in decoded[:8192]:
                    return ""
                return decoded.decode("utf-8", errors="replace")
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
        if int(r.headers.get("content-length") or 0) > MAX_TEXT_FILE_BYTES * 2:
            return ""
        data = r.json()
        content = data.get("content") or ""
        if data.get("encoding") == "base64":
            try:
                decoded = base64.b64decode(content)
                if len(decoded) > MAX_TEXT_FILE_BYTES or b"\x00" in decoded[:8192]:
                    return ""
                return decoded.decode("utf-8", errors="replace")
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
    slash_path = "/" in name_or_path
    if known_paths:
        for p in known_paths:
            if p == name_or_path or p.endswith("/" + name_or_path) or p.endswith(name_or_path):
                candidates.append(p)
            elif p.lower().endswith("/" + name_or_path.lower()) or p.lower().endswith(
                name_or_path.lower()
            ):
                candidates.append(p)

    # path já completo
    if slash_path:
        candidates.insert(0, name_or_path)
    elif not known_paths:
        for prefix in _COMMON_PREFIXES:
            candidates.append(f"{prefix}{name_or_path}")

    # dedupe preservando ordem
    seen: set[str] = set()
    ordered: list[str] = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            ordered.append(c)

    for path in ordered[:20]:
        text = await fetch_raw_content(owner, repo, path, ref=ref)
        if text:
            return path, text
    return "", ""
