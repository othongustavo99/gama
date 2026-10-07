"""API do Code Analyzer (compat: prefix /project).

Endpoints:
  POST /project/ingest          — ZIP
  POST /project/ingest/github   — GitHub URL ou owner/repo
  POST /project/ingest/pdf      — PDF
  GET  /project/{id}
  POST /project/{id}/context    — contexto síncrono
  POST /project/{id}/context/async — contexto com fetch GitHub
"""

from __future__ import annotations

import logging
from typing import List, Optional

from fastapi import APIRouter, File, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field

from ..core.code_analyzer import (
    build_query_context,
    get_project_summary,
    ingest_github,
    ingest_pdf,
    ingest_zip,
)
from ..core.code_analyzer.pipeline import build_query_context_async
from ..core.code_analyzer.source_detector import parse_github_url

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


@router.post("/ingest")
async def project_ingest(
    file: UploadFile = File(...),
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    name = file.filename or "project.zip"
    if not name.lower().endswith(".zip"):
        raise HTTPException(400, "Envie um arquivo .zip")
    raw = await file.read()
    if len(raw) < 64:
        raise HTTPException(400, "ZIP inválido ou vazio")
    try:
        summary = ingest_zip(
            raw, name=name, user_id=(x_user_id or "default").strip()
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("ingest failed")
        raise HTTPException(500, f"Falha ao indexar projeto: {e}") from e
    return {"ok": True, **summary}


@router.post("/ingest/github")
async def project_ingest_github(
    body: GitHubIngestRequest,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    owner, repo, branch = body.owner, body.repo, body.branch or "main"
    if body.url:
        gh = parse_github_url(body.url)
        if not gh:
            raise HTTPException(400, "URL GitHub inválida")
        owner, repo, branch = gh["owner"], gh["repo"], gh.get("branch") or branch
    if not owner or not repo:
        raise HTTPException(400, "Informe url ou owner/repo")
    try:
        summary = await ingest_github(
            owner, repo, branch=branch, user_id=(x_user_id or "default").strip()
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("github ingest failed")
        raise HTTPException(500, f"Falha ao indexar GitHub: {e}") from e
    return {"ok": True, **summary}


@router.post("/ingest/pdf")
async def project_ingest_pdf(
    file: UploadFile = File(...),
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    name = file.filename or "document.pdf"
    if not name.lower().endswith(".pdf"):
        raise HTTPException(400, "Envie um arquivo .pdf")
    raw = await file.read()
    if len(raw) < 64:
        raise HTTPException(400, "PDF inválido ou vazio")
    try:
        summary = ingest_pdf(
            raw, name=name, user_id=(x_user_id or "default").strip()
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("pdf ingest failed")
        raise HTTPException(500, f"Falha ao indexar PDF: {e}") from e
    return {"ok": True, **summary}


@router.get("/{project_id}")
async def project_get(project_id: str):
    s = get_project_summary(project_id)
    if not s:
        raise HTTPException(404, "Projeto não encontrado ou expirado")
    return s


@router.post("/{project_id}/context")
async def project_context(project_id: str, body: ContextRequest):
    try:
        ctx = build_query_context(
            project_id,
            body.query,
            max_tokens=body.max_tokens,
            extra_paths=body.extra_paths,
            level=body.level,
        )
    except Exception as e:
        logger.exception("context failed")
        raise HTTPException(500, str(e)) from e
    return {
        "ok": True,
        "project_id": project_id,
        "context": ctx,
        "chars": len(ctx),
    }


@router.post("/{project_id}/context/async")
async def project_context_async(project_id: str, body: ContextRequest):
    try:
        ctx = await build_query_context_async(
            project_id,
            body.query,
            max_tokens=body.max_tokens,
            extra_paths=body.extra_paths,
            level=body.level,
        )
    except Exception as e:
        logger.exception("context async failed")
        raise HTTPException(500, str(e)) from e
    return {
        "ok": True,
        "project_id": project_id,
        "context": ctx,
        "chars": len(ctx),
    }
