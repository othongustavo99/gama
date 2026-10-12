"""Cache em disco e controle de concorrência para materializar repositórios GitHub.

- Cache por commit (`DATA_DIR/github_cache/<owner>__<repo>/<sha>/`): o mesmo commit
  nunca é baixado duas vezes, mesmo por usuários diferentes.
- Downloads simultâneos do mesmo commit compartilham uma única tarefa (dedupe).
- Limite global de materializações em paralelo (evita estourar memória e a cota).
- Evicção por tamanho (LRU) e por idade, para o volume não encher.

Variáveis de ambiente:
  GITHUB_CACHE_MAX_MB            (padrão 2048)  teto total do cache em disco
  GITHUB_CACHE_TTL_HOURS         (padrão 168)   idade máxima de um commit no cache
  GITHUB_MATERIALIZE_CONCURRENCY (padrão 2)     materializações simultâneas no processo
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import time
import uuid
import weakref
from pathlib import Path
from typing import Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

_OWNER_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_COMPLETE = ".complete"
_MANIFEST = "manifest.json"


def _int_env(name: str, default: int) -> int:
    try:
        return max(1, int(os.getenv(name, str(default))))
    except (TypeError, ValueError):
        return default


def cache_root() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[3] / "data"
    p = base / "github_cache"
    p.mkdir(parents=True, exist_ok=True)
    return p


def cache_dir(owner: str, repo: str, commit_sha: str) -> Path:
    """Diretório do cache para um commit. Valida tudo que vira parte de caminho."""
    if not _OWNER_REPO_RE.fullmatch(owner or "") or not _OWNER_REPO_RE.fullmatch(repo or ""):
        raise ValueError("owner/repo inválidos")
    if not _SHA_RE.fullmatch(commit_sha or ""):
        raise ValueError("commit SHA inválido")
    return cache_root() / f"{owner}__{repo}" / commit_sha


def is_complete(d: Path) -> bool:
    return (d / _COMPLETE).is_file()


def read_manifest(d: Path) -> dict:
    import json

    try:
        return json.loads((d / _MANIFEST).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def publish(tmp_dir: Path, final_dir: Path, manifest: dict) -> Path:
    """Move um download concluído para o cache de forma atômica."""
    import json

    (tmp_dir / _MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    (tmp_dir / _COMPLETE).write_text(str(time.time()), encoding="utf-8")
    final_dir.parent.mkdir(parents=True, exist_ok=True)
    if is_complete(final_dir):  # outro processo publicou primeiro
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return final_dir
    shutil.rmtree(final_dir, ignore_errors=True)
    os.replace(tmp_dir, final_dir)
    evict_if_needed()
    return final_dir


def new_tmp_dir(owner: str, repo: str) -> Path:
    # Defense in depth: callers must not be able to introduce separators or
    # traversal segments into the cache's temporary directory name.
    if not _OWNER_REPO_RE.fullmatch(owner or "") or not _OWNER_REPO_RE.fullmatch(repo or ""):
        raise ValueError("owner/repo inválidos")
    d = cache_root() / ".tmp" / f"{owner}__{repo}-{uuid.uuid4().hex[:12]}"
    try:
        d.resolve().relative_to(cache_root().resolve())
    except ValueError as exc:
        raise ValueError("diretório temporário fora do cache") from exc
    d.mkdir(parents=True, exist_ok=True)
    return d


def _entries_with_size(root: Path) -> list[tuple[float, int, Path]]:
    """(mtime, bytes, diretório) de cada commit completo no cache."""
    out: list[tuple[float, int, Path]] = []
    for owner_repo in root.iterdir():
        if not owner_repo.is_dir() or owner_repo.name.startswith("."):
            continue
        for commit in owner_repo.iterdir():
            if not commit.is_dir() or not is_complete(commit):
                continue
            size = 0
            for f in commit.rglob("*"):
                if f.is_file():
                    try:
                        size += f.stat().st_size
                    except OSError:
                        pass
            out.append(((commit / _COMPLETE).stat().st_mtime, size, commit))
    return out


def evict_if_needed(now: Optional[float] = None) -> int:
    """Remove commits expirados e, se preciso, os mais antigos até caber no limite.

    Retorna quantos commits foram removidos.
    """
    now = now or time.time()
    ttl = _int_env("GITHUB_CACHE_TTL_HOURS", 168) * 3600
    limit = _int_env("GITHUB_CACHE_MAX_MB", 2048) * 1024 * 1024
    entries = _entries_with_size(cache_root())
    removed = 0
    keep: list[tuple[float, int, Path]] = []
    for mtime, size, path in entries:
        if now - mtime > ttl:
            shutil.rmtree(path, ignore_errors=True)
            removed += 1
        else:
            keep.append((mtime, size, path))
    total = sum(size for _, size, _ in keep)
    for mtime, size, path in sorted(keep):  # mais antigos primeiro
        if total <= limit:
            break
        shutil.rmtree(path, ignore_errors=True)
        total -= size
        removed += 1
    if removed:
        logger.info("github cache: %s commit(s) removidos por evicção", removed)
    return removed


# ── concorrência por event loop ──────────────────────────────────────────────
# asyncio.Semaphore e Lock ficam presos ao loop em que foram usados; guardamos um
# conjunto por loop para que testes (asyncio.run repetido) e o servidor funcionem.
_LIMITERS: "weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, dict]" = weakref.WeakKeyDictionary()


def _loop_state() -> dict:
    loop = asyncio.get_running_loop()
    state = _LIMITERS.get(loop)
    if state is None:
        state = {
            "materialize": asyncio.Semaphore(_int_env("GITHUB_MATERIALIZE_CONCURRENCY", 2)),
            "inflight": {},
        }
        _LIMITERS[loop] = state
    return state


async def run_deduplicated(key: str, factory: Callable[[], Awaitable[Path]]) -> Path:
    """Executa `factory` uma vez por chave; chamadas concorrentes esperam o mesmo resultado."""
    state = _loop_state()
    inflight: dict = state["inflight"]
    if key in inflight:
        return await asyncio.shield(inflight[key])
    task = asyncio.ensure_future(factory())
    inflight[key] = task
    try:
        return await asyncio.shield(task)
    finally:
        inflight.pop(key, None)


async def with_materialize_slot(coro_factory: Callable[[], Awaitable]):
    """Limita quantos repositórios são baixados ao mesmo tempo no processo."""
    async with _loop_state()["materialize"]:
        return await coro_factory()
