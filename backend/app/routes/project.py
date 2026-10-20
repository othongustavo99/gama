"""API do Code Analyzer com isolamento por usuário e relatório de cobertura.

Endpoints:
  POST /project/ingest                    — ZIP
  POST /project/ingest/github             — GitHub URL ou owner/repo
  POST /project/ingest/pdf|docx           — documentos
  GET  /project/{id}                      — resumo (somente proprietário)
  POST /project/{id}/context              — contexto + cobertura (somente proprietário)
  POST /project/{id}/context/async        — contexto async + cobertura
"""

from __future__ import annotations

import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import BaseModel, Field

from ..core.identity import current_user_id
from ..core.code_analyzer import (
    build_query_context,
    get_project_summary,
    ingest_github,
    ingest_pdf,
    ingest_docx,
    ingest_zip,
)
from ..core.code_analyzer.index_store import load_meta
from ..core.code_analyzer.pipeline import build_query_context_async, build_coverage_report
from ..core.code_analyzer.source_detector import parse_github_url
from ._upload import read_upload_limited

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/project", tags=["project", "code-analyzer"])


class ContextRequest(BaseModel):
    query: str = Field(min_length=1, max_length=4000)
    max_tokens: int = Field(default=4500, ge=1000, le=16000)
    extra_paths: Optional[List[str]] = None
    level: Optional[str] = Field(default=None, description="quick|targeted|deep")


class GitHubIngestRequest(BaseModel):
    url: Optional[str] = None
    owner: Optional[str] = None
    repo: Optional[str] = None
    branch: Optional[str] = "main"
    path: Optional[str] = None


def _require_project_owner(project_id: str, user_id: str) -> dict:
    """Devolve os metadados só ao proprietário; 404 evita revelar projeto alheio."""
    meta = load_meta(project_id)
    if not meta or meta.get("user_id", "default") != user_id:
        raise HTTPException(404, "Projeto não encontrado ou expirado")
    return meta


@router.post("/ingest")
async def project_ingest(
    file: UploadFile = File(...),
    user_id: str = Depends(current_user_id),
):
    name = file.filename or "project.zip"
    if not name.lower().endswith(".zip"):
        raise HTTPException(400, "Envie um arquivo .zip")
    raw = await read_upload_limited(file)
    if len(raw) < 64:
        raise HTTPException(400, "ZIP inválido ou vazio")
    try:
        summary = ingest_zip(raw, name=name, user_id=user_id)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        logger.exception("ingest failed")
        raise HTTPException(500, "Falha ao indexar projeto") from exc
    return {"ok": True, **summary}


@router.post("/ingest/github")
async def project_ingest_github(
    body: GitHubIngestRequest,
    user_id: str = Depends(current_user_id),
):
    owner, repo, branch = body.owner, body.repo, body.branch or "main"
    path_prefix = body.path or ""
    linked_path = ""
    if body.url:
        gh = parse_github_url(body.url)
        if not gh:
            raise HTTPException(400, "URL GitHub inválida")
        owner, repo, branch = gh["owner"], gh["repo"], gh.get("branch") or branch
        if gh.get("object_type") == "tree":
            path_prefix = gh.get("path") or path_prefix
        elif gh.get("object_type") == "blob":
            linked_path = gh.get("path") or ""
    if not owner or not repo:
        raise HTTPException(400, "Informe url ou owner/repo")
    try:
        summary = await ingest_github(
            owner, repo, branch=branch, path_prefix=path_prefix, user_id=user_id
        )
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        logger.exception("github ingest failed")
        raise HTTPException(500, "Falha ao indexar GitHub") from exc
    return {"ok": True, **summary, "linked_path": linked_path}


@router.post("/ingest/pdf")
async def project_ingest_pdf(
    file: UploadFile = File(...),
    user_id: str = Depends(current_user_id),
):
    name = file.filename or "document.pdf"
    if not name.lower().endswith(".pdf"):
        raise HTTPException(400, "Envie um arquivo .pdf")
    raw = await read_upload_limited(file)
    if len(raw) < 64:
        raise HTTPException(400, "PDF inválido ou vazio")
    try:
        summary = ingest_pdf(raw, name=name, user_id=user_id)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        logger.exception("pdf ingest failed")
        raise HTTPException(500, "Falha ao indexar PDF") from exc
    return {"ok": True, **summary}


@router.post("/ingest/docx")
async def project_ingest_docx(
    file: UploadFile = File(...),
    user_id: str = Depends(current_user_id),
):
    name = file.filename or "document.docx"
    if not name.lower().endswith(".docx"):
        raise HTTPException(400, "Envie um arquivo .docx")
    raw = await read_upload_limited(file)
    if len(raw) < 32:
        raise HTTPException(400, "DOCX inválido ou vazio")
    try:
        summary = ingest_docx(raw, name=name, user_id=user_id)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        logger.exception("docx ingest failed")
        raise HTTPException(500, "Falha ao indexar DOCX") from exc
    return {"ok": True, **summary}


@router.get("/{project_id}")
async def project_get(project_id: str, user_id: str = Depends(current_user_id)):
    _require_project_owner(project_id, user_id)
    summary = get_project_summary(project_id)
    if not summary:
        raise HTTPException(404, "Projeto não encontrado ou expirado")
    return summary


@router.post("/{project_id}/context")
async def project_context(
    project_id: str,
    body: ContextRequest,
    user_id: str = Depends(current_user_id),
):
    _require_project_owner(project_id, user_id)
    try:
        ctx = build_query_context(
            project_id, body.query, max_tokens=body.max_tokens,
            extra_paths=body.extra_paths, level=body.level,
        )
        coverage = build_coverage_report(project_id, ctx, level=body.level)
    except Exception as exc:
        logger.exception("context failed")
        raise HTTPException(500, "Falha ao montar contexto do projeto") from exc
    return {"ok": True, "project_id": project_id, "context": ctx, "chars": len(ctx), "coverage": coverage}


@router.post("/{project_id}/context/async")
async def project_context_async(
    project_id: str,
    body: ContextRequest,
    user_id: str = Depends(current_user_id),
):
    _require_project_owner(project_id, user_id)
    try:
        ctx = await build_query_context_async(
            project_id, body.query, max_tokens=body.max_tokens,
            extra_paths=body.extra_paths, level=body.level,
        )
        coverage = build_coverage_report(project_id, ctx, level=body.level)
    except Exception as exc:
        logger.exception("context async failed")
        raise HTTPException(500, "Falha ao montar contexto assíncrono do projeto") from exc
    return {"ok": True, "project_id": project_id, "context": ctx, "chars": len(ctx), "coverage": coverage}
