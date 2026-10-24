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
from .change_report import snapshot_tree, compare_snapshots, diff_preview, MAX_PREVIEW_BYTES
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
        "source_coverage": report.get("source_coverage"),
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
    import io
    import zipfile
    meta = load_meta(project_id) or {}
    expected_paths = {str(f.get('path')) for f in (meta.get('map') or {}).get('files', []) if f.get('path')}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        packed_paths = set(archive.namelist())
    missing = sorted(expected_paths - packed_paths)
    report['source_coverage'] = {
        'indexed_files': len(expected_paths),
        'packaged_indexed_files': len(expected_paths & packed_paths),
        'missing_indexed_files': len(missing),
        'missing_paths_sample': missing[:60],
        'complete_as_indexed': not missing and not report['truncated'],
        'note': 'Cobertura relativa ao índice conhecido; árvore GitHub pode estar parcial.',
    }
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
            "source_coverage": report["source_coverage"],
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
    if not validation.get('ok'):
        raise ValueError('ZIP inválido; nenhum arquivo foi publicado')
    # Falhas de sintaxe *comprovadas* impedem entregar código gerado como se
    # estivesse pronto. Linguagens sem parser (Dart/JS etc.) seguem claramente
    # marcadas como não verificadas, sem prometer que compilam.
    if source_validation.get('issues'):
        problems = source_validation['issues'][:8]
        raise ValueError('Arquivos gerados contêm problemas sintáticos: ' +
                         '; '.join(f"{x['path']}: {x['message']}" for x in problems))
    import hashlib
    manifest = {
        'files': [
            {'path': path.replace('\\', '/'), 'bytes': len(content.encode('utf-8')),
             'sha256': hashlib.sha256(content.encode('utf-8')).hexdigest()}
            for path, content in files.items()
        ],
        'verification': 'Conteúdo e ZIP válidos; compilação e testes não executados',
    }
    info = save_artifact(
        kind="zip",
        filename=filename,
        data=data,
        meta={"source": "files", "file_count": len(files), "validation": validation, "source_validation": source_validation, "file_manifest": manifest},
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
        "file_manifest": manifest,
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
    strict_edits: bool = True,
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
        normalized_extra = {
            _strip_root_prefix(k, root_name): v for k, v in (extra_files or {}).items()
        }
        # Baseline antes de mudar qualquer arquivo. Nunca modifica a fonte original.
        before = snapshot_tree(project_root)
        preview_paths = {e["path"] for e in normalized_edits if isinstance(e.get("path"), str)} | set(normalized_extra)
        before_previews = {}
        for rel in preview_paths:
            if rel not in before or before[rel]["bytes"] > MAX_PREVIEW_BYTES:
                continue
            before_previews[rel] = (project_root / rel).read_bytes()

        edit_result = apply_edits(project_root, normalized_edits)
        if strict_edits and not edit_result["ok"]:
            raise ValueError("Nenhum ZIP foi publicado porque houve falhas nas edições: "
                             + "; ".join(edit_result["errors"][:12]))

        if normalized_extra:
            written = write_files(project_root, normalized_extra, strict=True)
            edit_result["applied"].extend(f"write:{p}" for p in written)

        after = snapshot_tree(project_root)
        change_report = compare_snapshots(before, after)
        changed_paths = {path for path in (before.keys() | after.keys()) if before.get(path) != after.get(path)}
        previews = {}
        preview_budget = 50000
        for rel in sorted(changed_paths & preview_paths):
            if len(previews) >= 12 or preview_budget <= 0:
                break
            post = after.get(rel)
            new_raw = ((project_root / rel).read_bytes() if post and post["bytes"] <= MAX_PREVIEW_BYTES else None)
            preview = diff_preview(before_previews.get(rel), new_raw, rel) if (
                rel in before_previews or (post and post["bytes"] <= MAX_PREVIEW_BYTES)
            ) else None
            if preview:
                previews[rel] = preview[:preview_budget]
                preview_budget -= len(previews[rel])
        change_report["diff_previews"] = previews
        if strict_edits and (normalized_edits or normalized_extra) and change_report["changed_count"] == 0:
            raise ValueError("Nenhum arquivo foi alterado; ZIP de correção não publicado")

        data, report = build_zip_with_report(project_root, include_junk=include_junk)
        if not report["included"]:
            raise ValueError("O ZIP final ficaria vazio; nenhuma correção foi publicada")
        # Não aceitar 'sucesso' quando algum arquivo editado não está no ZIP final.
        import io
        import zipfile
        import hashlib
        expected = {p for p in changed_paths if p in after}
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            published_paths = set(archive.namelist())
            missing = expected - published_paths
            if missing:
                raise ValueError("Arquivos alterados não entraram no ZIP: " + ", ".join(sorted(missing)[:12]))
            for rel in sorted(expected):
                digest = hashlib.sha256()
                with archive.open(rel) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
                if digest.hexdigest() != after[rel]['sha256']:
                    raise ValueError(f"Arquivo {rel} difere do conteúdo corrigido; ZIP não publicado")
        change_report['archive_integrity'] = 'hash_sha256_confirmed' 
        report["source_validation"] = validate_source_archive(data)
        changed_issues = [issue for issue in report["source_validation"].get("issues", [])
                          if issue.get("path") in changed_paths]
        change_report["validation"] = {
            "changed_source_issues": changed_issues[:50],
            "syntax_checked": [p for p in report["source_validation"].get("checked_paths", []) if p in changed_paths],
            "note": "A validação sintática não executa Flutter, Dart, testes ou o projeto do usuário.",
        }
        if strict_edits and changed_issues:
            raise ValueError("Os arquivos modificados apresentam problemas sintáticos; ZIP não publicado: "
                             + "; ".join(f"{i['path']}: {i['message']}" for i in changed_issues[:8]))
        name = filename or "project_edited.zip"
        info = save_artifact(
            kind="zip",
            filename=name,
            data=data,
            meta={
                "source": src_label,
                "edits": edit_result,
                "change_report": change_report,
                "validation": report["validation"],
                "source_validation": report["source_validation"],
                "skipped_count": len(report["skipped"]),
            },
            user_id=user_id,
        )
        return _zip_response(info, report, edits=edit_result, change_report=change_report)
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
