"""Orquestra Document & Archive Builder.

Jobs principais:
  - prepare_project(project_id)         → materializa projeto GitHub (async, antes do ZIP)
  - build_zip_from_project(project_id)  → ZIP do workspace Code Analyzer
  - apply_edits_and_zip(project_id|zip, edits) → nova versão
  - build_zip_from_files({path: content})
  - build_pdf(title, sections)

Convenção de caminhos: as edições são relativas à RAIZ DO PROJETO, que é a
mesma pasta que vai para o ZIP. Quando o ZIP enviado tem uma única pasta de
topo (padrão do "Download ZIP" do GitHub), essa pasta é a raiz do projeto e o
prefixo dela é removido dos caminhos de edição, se o usuário o incluir.
"""

from __future__ import annotations

import logging
import shutil
from pathlib import Path
from typing import Any, Optional

from ..code_analyzer.index_store import load_meta, workspace
from .file_editor import apply_edits, write_files
from .github_materializer import materialize_github_project
from .pdf_builder import build_pdf as _build_pdf_bytes
from .store import load_artifact, list_recent, save_artifact, work_dir
from .validator import validate_pdf, validate_source_archive
from .zip_builder import (
    build_zip_with_report,
    copy_tree_filtered,
    extract_zip_safe,
)

logger = logging.getLogger(__name__)


def _project_scan_root(project_id: str) -> Optional[Path]:
    """Raiz do projeto no workspace do Code Analyzer.

    Usa o `scan_root` gravado na ingestão. Não tenta adivinhar pasta única:
    isso confundia repositórios cuja raiz legítima tem só um diretório.
    """
    meta = load_meta(project_id)
    if not meta:
        return None
    root = workspace(project_id)
    if not root.exists():
        return None
    rel = meta.get("scan_root") or "."
    if rel in (".", ""):
        return root
    return root / rel


def _content_root(job: Path) -> Path:
    """Para ZIPs enviados: se houver uma única pasta de topo, ela é a raiz do projeto."""
    children = [p for p in job.iterdir() if not p.name.startswith(".") and p.name != "__MACOSX"]
    if len(children) == 1 and children[0].is_dir():
        return children[0]
    return job


def _strip_root_prefix(path: str, root_name: Optional[str]) -> str:
    """Remove o nome da pasta de topo se o usuário o incluir no caminho da edição."""
    norm = (path or "").replace("\\", "/").strip()
    if root_name and norm.startswith(root_name + "/"):
        return norm[len(root_name) + 1 :]
    return norm


async def prepare_project(project_id: str) -> dict[str, Any]:
    """Garante que o projeto está pronto para ZIP (baixa arquivos se for GitHub)."""
    meta = load_meta(project_id)
    if not meta:
        raise ValueError(f"Projeto {project_id} não encontrado")
    if meta.get("github_lazy"):
        return await materialize_github_project(project_id)
    return {"ok": True, "written": 0, "skipped": []}


def _zip_response(info: dict[str, Any], report: dict[str, Any], **extra: Any) -> dict[str, Any]:
    return {
        "ok": True,
        "artifact_id": info["artifact_id"],
        "filename": info["filename"],
        "kind": "zip",
        "size": info["size"],
        "included_files": report.get("included", 0),
        "skipped_files": report.get("skipped", [])[:200],
        "skipped_count": len(report.get("skipped", [])),
        "truncated": bool(report.get("truncated")),
        "validation": report.get("validation"),
        "source_validation": report.get("source_validation"),
        "download_path": f"/artifacts/{info['artifact_id']}/download",
        **extra,
    }


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

    data, report = build_zip_with_report(scan, include_junk=include_junk)
    report["source_validation"] = validate_source_archive(data)
    if report["included"] == 0:
        raise ValueError(
            "O projeto não tem arquivos para compactar. Se for um repositório GitHub, "
            "os arquivos precisam ser baixados antes (prepare_project)."
        )
    name = filename or f"project_{project_id[:8]}.zip"
    info = save_artifact(
        kind="zip",
        filename=name,
        data=data,
        meta={
            "source": "project",
            "project_id": project_id,
            "validation": report["validation"],
            "source_validation": report["source_validation"],
            "skipped_count": len(report["skipped"]),
        },
        user_id=user_id,
    )
    return _zip_response(info, report)


def build_zip_from_files(
    files: dict[str, str],
    *,
    filename: str = "archive.zip",
    user_id: str = "default",
) -> dict[str, Any]:
    from .zip_builder import build_zip_from_mapping
    from .validator import validate_zip

    data = build_zip_from_mapping(files)
    validation = validate_zip(data)
    source_validation = validate_source_archive(data)
    info = save_artifact(
        kind="zip",
        filename=filename,
        data=data,
        meta={"source": "files", "file_count": len(files), "validation": validation, "source_validation": source_validation},
        user_id=user_id,
    )
    return {
        "ok": True,
        "artifact_id": info["artifact_id"],
        "filename": info["filename"],
        "kind": "zip",
        "size": info["size"],
        "validation": validation,
        "source_validation": source_validation,
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
    """Copia projeto ou extrai ZIP → aplica edits → recompacta → artefato novo.

    As edições e os extra_files são aplicados na mesma raiz que é zipada,
    então nada fica de fora do ZIP final.
    """
    job = work_dir()
    try:
        if project_id:
            scan = _project_scan_root(project_id)
            if not scan or not scan.exists():
                raise ValueError(f"Projeto {project_id} não encontrado")
            copy_tree_filtered(scan, job, include_junk=include_junk)
            project_root = job
            root_name = None
            src_label = f"project:{project_id}"
        elif zip_bytes:
            n = extract_zip_safe(zip_bytes, job)
            if n == 0:
                raise ValueError("ZIP vazio ou sem arquivos extraíveis")
            project_root = _content_root(job)
            root_name = project_root.name if project_root != job else None
            src_label = "zip_upload"
        else:
            raise ValueError("Informe project_id ou zip_bytes")

        normalized_edits = []
        for edit in edits or []:
            item = dict(edit)
            item["path"] = _strip_root_prefix(item.get("path", ""), root_name)
            normalized_edits.append(item)
        edit_result = apply_edits(project_root, normalized_edits)

        if extra_files:
            normalized_extra = {
                _strip_root_prefix(k, root_name): v for k, v in extra_files.items()
            }
            written = write_files(project_root, normalized_extra)
            edit_result["applied"].extend(f"write:{p}" for p in written)

        data, report = build_zip_with_report(project_root, include_junk=include_junk)
        report["source_validation"] = validate_source_archive(data)
        name = filename or "project_edited.zip"
        info = save_artifact(
            kind="zip",
            filename=name,
            data=data,
            meta={
                "source": src_label,
                "edits": edit_result,
                "validation": report["validation"],
                "source_validation": report["source_validation"],
                "skipped_count": len(report["skipped"]),
            },
            user_id=user_id,
        )
        return _zip_response(info, report, edits=edit_result)
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
    validation = validate_pdf(data)
    info = save_artifact(
        kind="pdf",
        filename=filename if filename.lower().endswith(".pdf") else f"{filename}.pdf",
        data=data,
        meta={
            "source": "pdf_builder",
            "title": title,
            "section_count": len(sections or []),
            "validation": validation,
        },
        user_id=user_id,
    )
    return {
        "ok": True,
        "artifact_id": info["artifact_id"],
        "filename": info["filename"],
        "kind": "pdf",
        "size": info["size"],
        "validation": validation,
        "download_path": f"/artifacts/{info['artifact_id']}/download",
    }


def get_artifact(
    artifact_id: str, user_id: Optional[str] = None
) -> Optional[dict[str, Any]]:
    return load_artifact(artifact_id, user_id=user_id)


def list_artifacts(user_id: Optional[str] = None, limit: int = 20) -> list[dict[str, Any]]:
    return list_recent(user_id=user_id, limit=limit)
