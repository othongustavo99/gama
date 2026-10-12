"""Materializa um projeto GitHub (indexado só por metadados) no workspace local.

A ingestão grava apenas a árvore (meta.json) e deixa o workspace vazio. Para um
ZIP completo é preciso baixar os arquivos. Este módulo:

- usa o SHA do commit (quando gravado na ingestão), então o ZIP é de UMA versão só;
- guarda o commit baixado em cache de disco e reaproveita em pedidos seguintes;
- deduplica downloads simultâneos do mesmo commit;
- limita quantos repositórios são baixados ao mesmo tempo no processo.

Quando não há commit_sha (projetos antigos), cai no branch, sem cache.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
from pathlib import Path
from typing import Any

from ..code_analyzer.github_cache import (
    cache_dir,
    is_complete,
    new_tmp_dir,
    publish,
    read_manifest,
    run_deduplicated,
    with_materialize_slot,
)
from ..code_analyzer.github_reader import fetch_raw_bytes
from ..code_analyzer.index_store import load_meta, save_meta, workspace
from .validator import validate_path_safe

logger = logging.getLogger(__name__)

MAX_CONCURRENT_DOWNLOADS = 10  # arquivos em paralelo dentro de um mesmo repositório
MAX_FILE_BYTES = 10 * 1024 * 1024  # era 8 MB
MAX_TOTAL_BYTES = 100 * 1024 * 1024  # era 80 MB
MAX_FILES = 12_000
_NOT_COPIED = {".complete", "manifest.json"}

# Entry-points usados quando a árvore da API veio vazia (raw-only / rate-limit).
_RAW_ONLY_PROBE_PATHS = (
    "README.md",
    "pubspec.yaml",
    "package.json",
    "pyproject.toml",
    "requirements.txt",
    "go.mod",
    "Cargo.toml",
    "pom.xml",
    "build.gradle",
    "Dockerfile",
    "docker-compose.yml",
    "lib/main.dart",
    "lib/app.dart",
    "src/main.dart",
    "src/App.tsx",
    "src/App.jsx",
    "src/index.ts",
    "src/index.js",
    "src/main.py",
    "main.py",
    "app.py",
    "main.js",
    "main.ts",
    "index.html",
    "backend/app/main.py",
    "backend/main.py",
    "app/main.py",
    "cmd/main.go",
    "main.go",
)


async def _download_into(
    target: Path, owner: str, repo: str, ref: str, files: list[dict[str, Any]]
) -> dict[str, Any]:
    """Baixa todos os arquivos para `target`. Retorna o relatório."""
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)
    skipped: list[dict[str, str]] = []
    written = 0
    total = 0
    lock = asyncio.Lock()

    async def _one(item: dict[str, Any]) -> None:
        nonlocal written, total
        rel = str(item.get("path") or "")
        if not validate_path_safe(rel):
            skipped.append({"path": rel, "reason": "caminho inseguro"})
            return
        if int(item.get("size") or 0) > MAX_FILE_BYTES:
            skipped.append({"path": rel, "reason": "arquivo grande demais"})
            return
        async with semaphore:
            data = await fetch_raw_bytes(owner, repo, rel, ref=ref, max_bytes=MAX_FILE_BYTES)
        if data is None:
            skipped.append({"path": rel, "reason": "indisponível ou acima do limite"})
            return
        async with lock:
            if total + len(data) > MAX_TOTAL_BYTES:
                skipped.append({"path": rel, "reason": "limite total atingido"})
                return
            total += len(data)
            written += 1
        dest = target / rel
        try:
            dest.resolve().relative_to(target.resolve())
        except ValueError:
            skipped.append({"path": rel, "reason": "fora do destino"})
            return
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

    await asyncio.gather(*(_one(f) for f in files))
    return {"written": written, "bytes": total, "skipped": skipped, "ref": ref}


def _link_or_copy(src: str, dst: str) -> None:
    """Hardlink quando possível (economiza disco); cópia como fallback."""
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def _copy_from_cache(cdir: Path, root: Path) -> None:
    shutil.copytree(
        cdir,
        root,
        dirs_exist_ok=True,
        copy_function=_link_or_copy,
        ignore=lambda _dir, names: [n for n in names if n in _NOT_COPIED],
    )


async def materialize_github_project(project_id: str, *, force: bool = False) -> dict[str, Any]:
    """Garante que os arquivos do projeto GitHub estão no workspace.

    Retorna {"ok", "written", "bytes", "skipped", "ref", "cached"}.
    """
    meta = load_meta(project_id)
    if not meta:
        raise ValueError(f"Projeto {project_id} não encontrado")
    if not meta.get("github_lazy"):
        return {"ok": True, "written": 0, "bytes": 0, "skipped": [], "note": "projeto não é GitHub lazy"}
    if meta.get("materialized") and not force:
        return {**meta.get("materialized_report", {}), "ok": True, "cached": True}

    source = meta.get("source") or {}
    owner, repo = source.get("owner"), source.get("repo")
    branch = source.get("branch") or "main"
    commit = str(source.get("commit_sha") or "").lower()
    if not owner or not repo:
        raise ValueError("Metadados do projeto GitHub incompletos")

    files = list((meta.get("map") or {}).get("files") or [])
    if len(files) > MAX_FILES:
        raise ValueError(f"Repositório com mais de {MAX_FILES} arquivos; use um subcaminho")

    # raw-only / rate-limit: árvore vazia — tenta entry-points convencionais
    # para o ZIP não sair sem nenhum arquivo.
    if not files:
        logger.warning(
            "materialize %s/%s: mapa vazio (raw-only?); sondando %d paths convencionais",
            owner,
            repo,
            len(_RAW_ONLY_PROBE_PATHS),
        )
        files = [{"path": p, "size": 0, "important": True} for p in _RAW_ONLY_PROBE_PATHS]
    else:
        # Prioriza arquivos marcados como important (manifests, entry-points)
        # para que, perto do limite de bytes, o essencial entre primeiro.
        files = sorted(files, key=lambda f: (not bool(f.get("important")), f.get("path") or ""))

    root = workspace(project_id)
    root.mkdir(parents=True, exist_ok=True)

    if commit:
        # Versão imutável: cache por commit + dedupe. O workspace recebe uma cópia.
        cdir = cache_dir(owner, repo, commit)
        cached = is_complete(cdir) and not force
        if not cached:
            async def _fetch() -> Path:
                tmp = new_tmp_dir(owner, repo)
                try:
                    report = await _download_into(tmp, owner, repo, commit, files)
                    return publish(tmp, cdir, report)
                except BaseException:
                    shutil.rmtree(tmp, ignore_errors=True)
                    raise

            cdir = await run_deduplicated(f"{owner}/{repo}@{commit}", lambda: with_materialize_slot(_fetch))
        _copy_from_cache(cdir, root)
        report = read_manifest(cdir)
        report["cached"] = cached
    else:
        logger.warning("projeto %s sem commit_sha; usando branch %s (sem cache)", project_id, branch)
        report = await with_materialize_slot(lambda: _download_into(root, owner, repo, branch, files))
        report["cached"] = False

    summary = {
        "written": int(report.get("written", 0)),
        "bytes": int(report.get("bytes", 0)),
        "skipped": list(report.get("skipped", []))[:200],
        "ref": report.get("ref", commit or branch),
        "cached": bool(report.get("cached")),
    }
    meta["materialized"] = True
    meta["materialized_report"] = summary
    save_meta(project_id, meta)
    logger.info(
        "GitHub %s/%s@%s materializado: %s arquivos (cache=%s), %s pulados",
        owner, repo, summary["ref"], summary["written"], summary["cached"], len(summary["skipped"]),
    )
    return {"ok": True, **summary}
