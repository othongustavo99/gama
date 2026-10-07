"""API do Document & Archive Builder.

Endpoints:
  POST /artifacts/zip/from-project
  POST /artifacts/zip/from-files
  POST /artifacts/zip/edit
  POST /artifacts/pdf
  GET  /artifacts
  GET  /artifacts/{id}
  GET  /artifacts/{id}/download
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, File, Header, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ..core.document_builder import (
    apply_edits_and_zip,
    build_pdf,
    build_zip_from_files,
    build_zip_from_project,
    get_artifact,
    list_artifacts,
)

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/artifacts", tags=["artifacts", "document-builder"])


class ZipFromProjectRequest(BaseModel):
    project_id: str = Field(min_length=6, max_length=32)
    filename: Optional[str] = None
    include_junk: bool = False


class ZipFromFilesRequest(BaseModel):
    files: Dict[str, str] = Field(..., description="path → content")
    filename: str = "archive.zip"


class EditItem(BaseModel):
    path: str
    action: str = "write"  # write|replace|append|delete|regex_replace
    content: Optional[str] = None
    old: Optional[str] = None
    new: Optional[str] = None
    pattern: Optional[str] = None
    replace_all: bool = False


class ZipEditRequest(BaseModel):
    project_id: Optional[str] = None
    edits: List[EditItem] = Field(default_factory=list)
    extra_files: Optional[Dict[str, str]] = None
    filename: Optional[str] = None
    include_junk: bool = False


class PdfSection(BaseModel):
    type: str = "paragraph"  # heading|paragraph|code|table|list|image|pagebreak|spacer|hr
    text: Optional[str] = None
    code: Optional[str] = None
    language: Optional[str] = None
    level: Optional[int] = 1
    headers: Optional[List[str]] = None
    rows: Optional[List[List[str]]] = None
    items: Optional[List[str]] = None
    ordered: bool = False
    path: Optional[str] = None
    data_base64: Optional[str] = None
    width: Optional[float] = None
    height: Optional[float] = None


class PdfRequest(BaseModel):
    title: str = "Documento"
    subtitle: str = ""
    author: str = "Gama"
    sections: List[PdfSection] = Field(default_factory=list)
    header: str = ""
    footer: str = "Gama · Document & Archive Builder"
    filename: str = "document.pdf"


def _uid(x_user_id: Optional[str]) -> str:
    return (x_user_id or "default").strip() or "default"


@router.post("/zip/from-project")
async def zip_from_project(
    body: ZipFromProjectRequest,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    try:
        return build_zip_from_project(
            body.project_id,
            filename=body.filename,
            include_junk=body.include_junk,
            user_id=_uid(x_user_id),
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip from project failed")
        raise HTTPException(500, str(e)) from e


@router.post("/zip/from-files")
async def zip_from_files(
    body: ZipFromFilesRequest,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    if not body.files:
        raise HTTPException(400, "files vazio")
    if len(body.files) > 500:
        raise HTTPException(400, "Máximo 500 arquivos por request")
    try:
        return build_zip_from_files(
            body.files, filename=body.filename, user_id=_uid(x_user_id)
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip from files failed")
        raise HTTPException(500, str(e)) from e


@router.post("/zip/edit")
async def zip_edit(
    body: ZipEditRequest,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    if not body.project_id and not body.edits and not body.extra_files:
        raise HTTPException(400, "Informe project_id e/ou edits")
    try:
        edits = [e.model_dump() for e in body.edits]
        return apply_edits_and_zip(
            project_id=body.project_id,
            edits=edits,
            extra_files=body.extra_files,
            filename=body.filename,
            include_junk=body.include_junk,
            user_id=_uid(x_user_id),
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip edit failed")
        raise HTTPException(500, str(e)) from e


@router.post("/zip/edit-upload")
async def zip_edit_upload(
    file: UploadFile = File(...),
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    """Recebe ZIP + campo form 'edits' JSON via multipart — simplificado: só extrai e rezipa.

    Para edits estruturados use /zip/edit com project_id após ingest.
    """
    name = file.filename or "upload.zip"
    if not name.lower().endswith(".zip"):
        raise HTTPException(400, "Envie um .zip")
    raw = await file.read()
    if len(raw) < 64:
        raise HTTPException(400, "ZIP inválido")
    try:
        result = apply_edits_and_zip(
            zip_bytes=raw,
            edits=[],
            filename=name.replace(".zip", "_copy.zip"),
            user_id=_uid(x_user_id),
        )
        return result
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip edit upload failed")
        raise HTTPException(500, str(e)) from e


@router.post("/pdf")
async def pdf_create(
    body: PdfRequest,
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    try:
        sections = [s.model_dump(exclude_none=True) for s in body.sections]
        return build_pdf(
            title=body.title,
            subtitle=body.subtitle,
            author=body.author,
            sections=sections,
            header=body.header,
            footer=body.footer,
            filename=body.filename,
            user_id=_uid(x_user_id),
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except RuntimeError as e:
        raise HTTPException(500, str(e)) from e
    except Exception as e:
        logger.exception("pdf create failed")
        raise HTTPException(500, str(e)) from e


@router.get("")
async def artifacts_list(
    x_user_id: Optional[str] = Header(default=None, alias="X-User-Id"),
):
    return {"ok": True, "artifacts": list_artifacts(user_id=_uid(x_user_id))}


@router.get("/{artifact_id}")
async def artifact_meta(artifact_id: str):
    info = get_artifact(artifact_id)
    if not info:
        raise HTTPException(404, "Artefato não encontrado ou expirado")
    # não devolve bytes
    out = {k: v for k, v in info.items() if k != "bytes"}
    out["download_path"] = f"/artifacts/{artifact_id}/download"
    return out


@router.get("/{artifact_id}/download")
async def artifact_download(artifact_id: str):
    info = get_artifact(artifact_id)
    if not info or not info.get("bytes"):
        raise HTTPException(404, "Artefato não encontrado ou expirado")
    media = {
        "zip": "application/zip",
        "pdf": "application/pdf",
    }.get(info.get("kind", ""), "application/octet-stream")
    return Response(
        content=info["bytes"],
        media_type=media,
        headers={
            "Content-Disposition": f'attachment; filename="{info.get("filename", "file")}"',
            "Content-Length": str(info.get("size") or len(info["bytes"])),
        },
    )
