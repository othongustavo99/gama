"""Materializa um projeto GitHub (indexado só por metadados) no workspace local.

A ingestão do GitHub grava apenas a árvore (meta.json) e deixa o workspace
vazio: o conteúdo é buscado sob demanda. Para gerar um ZIP completo é preciso
baixar todos os arquivos antes. Este módulo faz isso com concorrência limitada,
limites de tamanho e um relatório do que foi baixado ou ficou de fora.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Any

from ..code_analyzer.github_reader import fetch_raw_bytes
from ..code_analyzer.index_store import load_meta, save_meta, workspace
from .validator import validate_path_safe

logger = logging.getLogger(__name__)

MAX_CONCURRENT_DOWNLOADS = 8
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 80 * 1024 * 1024
MAX_FILES = 12_000


async def materialize_github_project(project_id: str, *, force: bool = False) -> dict[str, Any]:
    """Baixa todos os arquivos listados no mapa do projeto GitHub.

    Retorna um relatório {"ok", "written", "bytes", "skipped": [...]} e marca o
    projeto como materializado para não baixar de novo nas próximas chamadas.
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
    if not owner or not repo:
        raise ValueError("Metadados do projeto GitHub incompletos")

    files = (meta.get("map") or {}).get("files") or []
    if len(files) > MAX_FILES:
        raise ValueError(f"Repositório com mais de {MAX_FILES} arquivos; use um subcaminho")

    root = workspace(project_id)
    root.mkdir(parents=True, exist_ok=True)
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
        declared = int(item.get("size") or 0)
        if declared > MAX_FILE_BYTES:
            skipped.append({"path": rel, "reason": "arquivo grande demais"})
            return
        async with semaphore:
            data = await fetch_raw_bytes(owner, repo, rel, ref=branch, max_bytes=MAX_FILE_BYTES)
        if data is None:
            skipped.append({"path": rel, "reason": "indisponível ou acima do limite"})
            return
        async with lock:
            if total + len(data) > MAX_TOTAL_BYTES:
                skipped.append({"path": rel, "reason": "limite total atingido"})
                return
            total += len(data)
            written += 1
        target = (root / rel)
        try:
            target.resolve().relative_to(root.resolve())
        except ValueError:
            skipped.append({"path": rel, "reason": "fora do workspace"})
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    await asyncio.gather(*(_one(f) for f in files))

    report = {
        "ok": True,
        "written": written,
        "bytes": total,
        "skipped": skipped,
        "branch": branch,
    }
    meta["materialized"] = True
    meta["materialized_report"] = {k: v for k, v in report.items() if k != "ok"}
    save_meta(project_id, meta)
    logger.info("GitHub %s/%s materializado: %s arquivos, %s pulados", owner, repo, written, len(skipped))
    return report
