"""GitHub Reader — tree API + fetch seletivo de blobs (não baixa o repo inteiro)."""

from __future__ import annotations

import base64
import logging
import os
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)

GITHUB_API = "https://api.github.com"
DEFAULT_TIMEOUT = 30.0


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


async def get_repo_default_branch(owner: str, repo: str) -> str:
    url = f"{GITHUB_API}/repos/{owner}/{repo}"
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        r = await client.get(url)
        if r.status_code == 404:
            raise ValueError(f"Repositório não encontrado: {owner}/{repo}")
        r.raise_for_status()
        data = r.json()
        return data.get("default_branch") or "main"


async def get_tree(
    owner: str, repo: str, branch: str = "main"
) -> tuple[str, list[dict[str, Any]]]:
    """Retorna (tree_sha, lista de {path, sha, size, type})."""
    # resolve branch → commit → tree
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        # try branch ref
        ref_url = f"{GITHUB_API}/repos/{owner}/{repo}/git/ref/heads/{branch}"
        r = await client.get(ref_url)
        if r.status_code == 404:
            # fallback default
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


async def fetch_file_content(
    owner: str, repo: str, path: str, *, ref: str = "main"
) -> str:
    """Conteúdo de um arquivo via Contents API (base64)."""
    url = f"{GITHUB_API}/repos/{owner}/{repo}/contents/{path}"
    params = {"ref": ref}
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=_headers()) as client:
        r = await client.get(url, params=params)
        if r.status_code == 404:
            return ""
        r.raise_for_status()
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
