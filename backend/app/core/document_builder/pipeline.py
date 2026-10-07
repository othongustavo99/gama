"""Orquestra Document & Archive Builder.

Jobs principais:
  - build_zip_from_project(project_id)  → ZIP do workspace Code Analyzer
  - apply_edits_and_zip(project_id|zip, edits) → nova versão
  - build_zip_from_files({path: content})
  - build_pdf(title, sections)
"""

from __future__ import annotations

import logging
import shutil
from pathlib import Path
from typing import Any, Optional

from .file_editor import apply_edits, write_files
from .pdf_builder import build_pdf as _build_pdf_bytes
from .store import load_artifact, list_recent, save_artifact, work_dir
from .validator import validate_pdf, validate_zip
from .zip_builder import (
    build_zip_from_directory,
    build_zip_from_mapping,
    copy_tree_filtered,
    extract_zip_safe,
)

logger = logging.getLogger(__name__)


def _project_scan_root(project_id: str) -> Optional[Path]:
    """Resolve workspace do Code Analyzer / Project Analyzer."""
    try:
        from ..code_analyzer.index_store import load_meta, workspace
    except ImportError:
        try:
            from ..project_analyzer.index_store import load_meta, workspace  # type: ignore
        except ImportError:
            return None

    meta = load_meta(project_id)
    if not meta:
        return None
    root = workspace(project_id)
    if not root.exists():
        return None
    rel = meta.get("scan_root") or "."
    if rel in (".", "", None):
        children = [p for p in root.iterdir()]
        if len(children) == 1 and children[0].is_dir():
            return children[0]
        return root
    return root / rel


def build_zip_from_project(
    project_id: str,
    *,
    filename: Optional[str] = None,
    include_junk: bool = False,
    user_id: str = "default",
) -> dict[str, Any]:
    scan = _project_scan_root(project_id)
    if not scan or not scan.exists():
        raise ValueError(f"Projeto {project_id} não encontrado ou sem arquivos locais")

    data = build_zip_from_directory(scan, include_junk=include_junk)
    name = filename or f"project_{project_id[:8]}.zip"
    info = save_artifact(
        kind="zip",
        filename=name,
        data=data,
        meta={
            "source": "project",
            "project_id": project_id,
            "validation": validate_zip(data),
        },
        user_id=user_id,
    )
    return {
        "ok": True,
        "artifact_id": info["artifact_id"],
        "filename": info["filename"],
        "kind": "zip",
        "size": info["size"],
        "validation": info.get("validation"),
        "download_path": f"/artifacts/{info['artifact_id']}/download",
    }


def build_zip_from_files(
    files: dict[str, str],
    *,
    filename: str = "archive.zip",
    user_id: str = "default",
) -> dict[str, Any]:
    data = build_zip_from_mapping(files)
    info = save_artifact(
        kind="zip",
        filename=filename,
        data=data,
        meta={"source": "files", "file_count": len(files), "validation": validate_zip(data)},
        user_id=user_id,
    )
    return {
        "ok": True,
        "artifact_id": info["artifact_id"],
        "filename": info["filename"],
        "kind": "zip",
        "size": info["size"],
        "validation": info.get("validation"),
        "download_path": f"/artifacts/{info['artifact_id']}/download",
    }


def apply_edits_and_zip(
    *,
    project_id: Optional[str] = None,
    zip_bytes: Optional[bytes] = None,
    edits: list[dict[str, Any]],
    extra_files: Optional[dict[str, str]] = None,
    filename: Optional[str] = None,
    include_junk: bool = False,
    user_id: str = "default",
) -> dict[str, Any]:
    """Copia projeto ou extrai ZIP → aplica edits → recompacta → artefato novo."""
    job = work_dir()
    try:
        if project_id:
            scan = _project_scan_root(project_id)
            if not scan or not scan.exists():
                raise ValueError(f"Projeto {project_id} não encontrado")
            copy_tree_filtered(scan, job, include_junk=include_junk)
            src_label = f"project:{project_id}"
        elif zip_bytes:
            n = extract_zip_safe(zip_bytes, job)
            if n == 0:
                raise ValueError("ZIP vazio ou sem arquivos extraíveis")
            # strip single top-level folder
            children = [p for p in job.iterdir()]
            if len(children) == 1 and children[0].is_dir():
                # work inside that folder conceptually — copy up? keep as is
                pass
            src_label = "zip_upload"
        else:
            raise ValueError("Informe project_id ou zip_bytes")

        edit_result = apply_edits(job, edits)
        if extra_files:
            written = write_files(job, extra_files)
            edit_result["applied"].extend(f"write:{p}" for p in written)

        # se só tinha uma pasta raiz, zipar a partir dela
        zip_root = job
        children = [p for p in job.iterdir() if not p.name.startswith(".")]
        if len(children) == 1 and children[0].is_dir():
            zip_root = children[0]

        data = build_zip_from_directory(zip_root, include_junk=include_junk)
        name = filename or "project_edited.zip"
        info = save_artifact(
            kind="zip",
            filename=name,
            data=data,
            meta={
                "source": src_label,
                "edits": edit_result,
                "validation": validate_zip(data),
            },
            user_id=user_id,
        )
        return {
            "ok": True,
            "artifact_id": info["artifact_id"],
            "filename": info["filename"],
            "kind": "zip",
            "size": info["size"],
            "edits": edit_result,
            "validation": info.get("validation"),
            "download_path": f"/artifacts/{info['artifact_id']}/download",
        }
    finally:
        shutil.rmtree(job, ignore_errors=True)


def build_pdf(
    *,
    title: str = "Documento",
    subtitle: str = "",
    author: str = "Gama",
    sections: list[dict[str, Any]] | None = None,
    header: str = "",
    footer: str = "Gama · Document & Archive Builder",
    filename: str = "document.pdf",
    user_id: str = "default",
) -> dict[str, Any]:
    data = _build_pdf_bytes(
        title=title,
        subtitle=subtitle,
        author=author,
        sections=sections or [],
        header=header,
        footer=footer,
    )
    info = save_artifact(
        kind="pdf",
        filename=filename if filename.lower().endswith(".pdf") else f"{filename}.pdf",
        data=data,
        meta={
            "source": "pdf_builder",
            "title": title,
            "section_count": len(sections or []),
            "validation": validate_pdf(data),
        },
        user_id=user_id,
    )
    return {
        "ok": True,
        "artifact_id": info["artifact_id"],
        "filename": info["filename"],
        "kind": "pdf",
        "size": info["size"],
        "validation": info.get("validation"),
        "download_path": f"/artifacts/{info['artifact_id']}/download",
    }


def get_artifact(artifact_id: str) -> Optional[dict[str, Any]]:
    return load_artifact(artifact_id)


def list_artifacts(user_id: Optional[str] = None, limit: int = 20) -> list[dict[str, Any]]:
    return list_recent(user_id=user_id, limit=limit)
