"""Orquestra Extractor → Cleaner → Mapper → Search → Context."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Optional

from .code_search import search_files
from .context_builder import build_context
from .extractor import safe_extract
from .index_store import (
    cleanup_old,
    load_meta,
    new_project_id,
    save_meta,
    workspace,
)
from .mapper import extract_imports, extract_symbols, walk_project

logger = logging.getLogger(__name__)


def ingest_zip(
    zip_bytes: bytes,
    *,
    name: str = "project.zip",
    user_id: str = "default",
) -> dict[str, Any]:
    cleanup_old()
    project_id = new_project_id()
    root = workspace(project_id)
    if root.exists():
        import shutil

        shutil.rmtree(root, ignore_errors=True)
    n = safe_extract(zip_bytes, root)
    if n == 0:
        raise ValueError("ZIP vazio ou sem arquivos extraíveis")

    # strip single top-level folder if present
    children = [p for p in root.iterdir()]
    scan_root = root
    if len(children) == 1 and children[0].is_dir():
        scan_root = children[0]

    map_data = walk_project(scan_root)

    # symbols for important source files (lightweight index)
    symbol_index: dict[str, list[str]] = {}
    for fmeta in map_data["files"][:120]:
        if fmeta["lang"] in {"Dart", "Python", "TypeScript", "JavaScript", "Java", "Kotlin"}:
            p = scan_root / fmeta["path"]
            # path relative to scan_root already
            try:
                # files paths are relative to scan_root
                text = p.read_text(encoding="utf-8", errors="replace")[:80000]
                symbol_index[fmeta["path"]] = extract_symbols(text) + [
                    f"imp:{i}" for i in extract_imports(text)[:15]
                ]
            except Exception:
                pass

    meta = {
        "name": name,
        "user_id": user_id,
        "extracted_files": n,
        "scan_root": str(scan_root.relative_to(workspace(project_id)))
        if scan_root != root
        else ".",
        "map": map_data,
        "symbols": symbol_index,
    }
    save_meta(project_id, meta)

    return {
        "project_id": project_id,
        "name": name,
        "file_count": map_data["file_count"],
        "frameworks": map_data["frameworks"],
        "languages": map_data["languages"],
        "sample_paths": [f["path"] for f in map_data["files"][:25]],
    }


def _scan_root_for(project_id: str, meta: dict[str, Any]) -> Path:
    root = workspace(project_id)
    rel = meta.get("scan_root") or "."
    if rel in (".", "", None):
        children = [p for p in root.iterdir()]
        if len(children) == 1 and children[0].is_dir():
            return children[0]
        return root
    return root / rel


def get_project_summary(project_id: str) -> Optional[dict[str, Any]]:
    meta = load_meta(project_id)
    if not meta:
        return None
    m = meta.get("map") or {}
    return {
        "project_id": project_id,
        "name": meta.get("name"),
        "file_count": m.get("file_count"),
        "frameworks": m.get("frameworks"),
        "languages": m.get("languages"),
        "sample_paths": [f["path"] for f in (m.get("files") or [])[:30]],
    }


def build_query_context(
    project_id: str,
    query: str,
    *,
    max_tokens: int = 4500,
    extra_paths: Optional[list[str]] = None,
) -> str:
    meta = load_meta(project_id)
    if not meta:
        return f"(Project Analyzer: projeto {project_id} não encontrado ou expirado. Envie o ZIP de novo.)"

    scan = _scan_root_for(project_id, meta)
    map_data = meta.get("map") or {"files": [], "file_count": 0}
    files = map_data.get("files") or []

    ranked = search_files(scan, files, query, top_k=18)

    # force-include extra_paths if requested (second pass)
    if extra_paths:
        have = {r["path"] for r in ranked}
        for ep in extra_paths:
            ep = ep.strip().lstrip("./")
            if not ep or ep in have:
                continue
            p = scan / ep
            if p.is_file():
                try:
                    text = p.read_text(encoding="utf-8", errors="replace")
                    ranked.insert(
                        0,
                        {
                            "path": ep,
                            "score": 999,
                            "important": True,
                            "text": text,
                        },
                    )
                except Exception:
                    pass

    return build_context(map_data, ranked, query, max_tokens=max_tokens)
