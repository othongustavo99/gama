"""API do Project Analyzer."""

from __future__ import annotations

import logging
from typing import List, Optional

from fastapi import APIRouter, File, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field

from ..core.project_analyzer import (
    build_query_context,
    get_project_summary,
    ingest_zip,
)

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/project", tags=["project"])


class ContextRequest(BaseModel):
    query: str = Field(min_length=1, max_length=4000)
    max_tokens: int = Field(default=4500, ge=1000, le=12000)
    extra_paths: Optional[List[str]] = None


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
