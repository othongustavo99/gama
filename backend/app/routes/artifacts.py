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
import stat
from contextlib import contextmanager
from zipfile import BadZipFile, ZipFile
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, Header
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from ..core.document_builder import (
    apply_edits_and_zip,
    build_pdf,
    build_zip_from_files,
    build_zip_from_project,
    get_artifact,
    list_artifacts,
)
from ..core.document_builder.pipeline import prepare_project
from ._upload import read_upload_limited
from ..core.identity import current_user_id
from ..core.commercial_plans import artifact_route
from ..core.code_analyzer.index_store import load_meta
from ..core.document_builder.store import ArtifactStorageLimitError, verify_artifact_file

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/artifacts", tags=["artifacts", "document-builder"])


def _require_project_owner(project_id: str, user_id: str) -> None:
    meta = load_meta(project_id)
    if not meta or meta.get("user_id", "default") != user_id:
        # 404 evita confirmar a existência de projeto privado alheio.
        raise HTTPException(404, "Projeto não encontrado ou expirado")


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


@router.post("/zip/from-project")
@artifact_route
async def zip_from_project(
    body: ZipFromProjectRequest,
    user_id: str = Depends(current_user_id),
    idempotency_key: str | None = Header(default=None, alias="X-Idempotency-Key"),
):
    try:
        _require_project_owner(body.project_id, user_id)
        # Projetos GitHub só têm metadados até aqui: baixa os arquivos depois de
        # confirmar a propriedade do projeto.
        await prepare_project(body.project_id)
        return build_zip_from_project(
            body.project_id,
            filename=body.filename,
            include_junk=body.include_junk,
            user_id=user_id,
        )
    except HTTPException:
        raise
    except ArtifactStorageLimitError as e:
        raise HTTPException(507, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip from project failed")
        raise HTTPException(500, str(e)) from e


@router.post("/zip/from-files")
@artifact_route
async def zip_from_files(
    body: ZipFromFilesRequest,
    user_id: str = Depends(current_user_id),
    idempotency_key: str | None = Header(default=None, alias="X-Idempotency-Key"),
):
    if not body.files:
        raise HTTPException(400, "files vazio")
    if len(body.files) > 500:
        raise HTTPException(400, "Máximo 500 arquivos por request")
    try:
        return build_zip_from_files(
            body.files, filename=body.filename, user_id=user_id
        )
    except ArtifactStorageLimitError as e:
        raise HTTPException(507, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip from files failed")
        raise HTTPException(500, str(e)) from e


@router.post("/zip/edit")
@artifact_route
async def zip_edit(
    body: ZipEditRequest,
    user_id: str = Depends(current_user_id),
    idempotency_key: str | None = Header(default=None, alias="X-Idempotency-Key"),
):
    if not body.project_id and not body.edits and not body.extra_files:
        raise HTTPException(400, "Informe project_id e/ou edits")
    try:
        if body.project_id:
            _require_project_owner(body.project_id, user_id)
            await prepare_project(body.project_id)
        edits = [e.model_dump() for e in body.edits]
        return apply_edits_and_zip(
            project_id=body.project_id,
            edits=edits,
            extra_files=body.extra_files,
            filename=body.filename,
            include_junk=body.include_junk,
            user_id=user_id,
        )
    except HTTPException:
        raise
    except ArtifactStorageLimitError as e:
        raise HTTPException(507, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip edit failed")
        raise HTTPException(500, str(e)) from e


@router.post("/zip/edit-upload")
@artifact_route
async def zip_edit_upload(
    file: UploadFile = File(...),
    user_id: str = Depends(current_user_id),
    idempotency_key: str | None = Header(default=None, alias="X-Idempotency-Key"),
):
    """Recebe ZIP + campo form 'edits' JSON via multipart — simplificado: só extrai e rezipa.

    Para edits estruturados use /zip/edit com project_id após ingest.
    """
    name = file.filename or "upload.zip"
    if not name.lower().endswith(".zip"):
        raise HTTPException(400, "Envie um .zip")
    raw = await read_upload_limited(file)
    if len(raw) < 64:
        raise HTTPException(400, "ZIP inválido")
    try:
        result = apply_edits_and_zip(
            zip_bytes=raw,
            edits=[],
            filename=name.replace(".zip", "_copy.zip"),
            user_id=user_id,
        )
        return result
    except ArtifactStorageLimitError as e:
        raise HTTPException(507, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:
        logger.exception("zip edit upload failed")
        raise HTTPException(500, str(e)) from e


@router.post("/pdf")
@artifact_route
async def pdf_create(
    body: PdfRequest,
    user_id: str = Depends(current_user_id),
    idempotency_key: str | None = Header(default=None, alias="X-Idempotency-Key"),
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
            user_id=user_id,
        )
    except ArtifactStorageLimitError as e:
        raise HTTPException(507, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except RuntimeError as e:
        raise HTTPException(500, str(e)) from e
    except Exception as e:
        logger.exception("pdf create failed")
        raise HTTPException(500, str(e)) from e


@router.get("")
async def artifacts_list(
    user_id: str = Depends(current_user_id),
):
    return {"ok": True, "artifacts": list_artifacts(user_id=user_id)}


@router.get("/{artifact_id}")
async def artifact_meta(
    artifact_id: str,
    user_id: str = Depends(current_user_id),
):
    info = get_artifact(artifact_id, user_id=user_id)
    if not info:
        raise HTTPException(404, "Artefato não encontrado ou expirado")
    # não devolve bytes
    # Não exponha o caminho absoluto do armazenamento no servidor ao cliente.
    out = {k: v for k, v in info.items() if k not in {"bytes", "path"}}
    out["download_path"] = f"/artifacts/{artifact_id}/download"
    return out


@router.get("/{artifact_id}/download")
async def artifact_download(
    artifact_id: str,
    user_id: str = Depends(current_user_id),
):
    info = get_artifact(artifact_id, user_id=user_id)
    if not info or not info.get("path"):
        raise HTTPException(404, "Artefato não encontrado ou expirado")
    # Evita distribuir bytes alterados/corrompidos no volume após a geração.
    # A verificação é realizada no disco, não apenas no JSON do artefato.
    if not verify_artifact_file(info):
        logger.error("Artifact integrity mismatch: %s", artifact_id)
        raise HTTPException(409, "O arquivo armazenado falhou na verificação de integridade")
    media = {
        "zip": "application/zip",
        "pdf": "application/pdf",
        "video": "video/mp4",
    }.get(info.get("kind", ""), "application/octet-stream")
    return FileResponse(
        path=info["path"],
        filename=info.get("filename", "arquivo"),
        media_type=media,
        headers={
            "Cache-Control": "private, no-store",
            "X-Gama-SHA256": str(info["sha256"]),
            "X-Gama-File-Size": str(info["size"]),
        },
    )


_MAX_TEXT_PREVIEW_BYTES = 1024 * 1024
_PRIVATE_RESPONSE = {"Cache-Control": "private, no-store"}


@contextmanager
def _open_artifact_zip(artifact_id: str, user_id: str):
    info = get_artifact(artifact_id, user_id=user_id)
    if not info or info.get("kind") != "zip" or not info.get("path"):
        raise HTTPException(404, "Arquivo ZIP não encontrado ou expirado")
    if not verify_artifact_file(info):
        raise HTTPException(409, "O ZIP falhou na verificação de integridade")
    try:
        with ZipFile(info["path"]) as archive:
            yield archive, info
    except (BadZipFile, OSError, RuntimeError, NotImplementedError) as error:
        raise HTTPException(409, "Não foi possível ler o ZIP") from error


def _is_zip_file(entry):
    return not entry.is_dir() and not stat.S_ISLNK(entry.external_attr >> 16)


def _zip_entry(archive: ZipFile, index: int):
    entries = archive.infolist()
    if index < 0 or index >= len(entries) or not _is_zip_file(entries[index]):
        raise HTTPException(404, "Arquivo não encontrado no ZIP")
    return entries[index]


@router.get("/{artifact_id}/files")
def artifact_files(artifact_id: str, user_id: str = Depends(current_user_id)):
    with _open_artifact_zip(artifact_id, user_id) as (archive, _):
        return JSONResponse({
            "files": [
                {"index": index, "name": entry.filename, "size": entry.file_size}
                for index, entry in enumerate(archive.infolist())
                if _is_zip_file(entry)
            ]
        }, headers=_PRIVATE_RESPONSE)


@router.get("/{artifact_id}/files/{index}")
def artifact_file_preview(artifact_id: str, index: int, user_id: str = Depends(current_user_id)):
    with _open_artifact_zip(artifact_id, user_id) as (archive, info):
        entry = _zip_entry(archive, index)
        if entry.file_size > _MAX_TEXT_PREVIEW_BYTES:
            return JSONResponse({"content": None, "reason": "too_large"}, headers=_PRIVATE_RESPONSE)
        with archive.open(entry) as file:
            raw = file.read(_MAX_TEXT_PREVIEW_BYTES + 1)
        if len(raw) > _MAX_TEXT_PREVIEW_BYTES:
            return JSONResponse({"content": None, "reason": "too_large"}, headers=_PRIVATE_RESPONSE)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = None
        if text is None or "\x00" in text:
            return JSONResponse({"content": None, "reason": "binary"}, headers=_PRIVATE_RESPONSE)
        response = {"content": text}
        report = info.get("change_report")
        previews = report.get("diff_previews") if isinstance(report, dict) else None
        diff = previews.get(entry.filename) if isinstance(previews, dict) else None
        if isinstance(diff, str) and diff:
            response["diff"] = diff
        return JSONResponse(response, headers=_PRIVATE_RESPONSE)


@router.get("/{artifact_id}/files/{index}/download")
def artifact_file_download(artifact_id: str, index: int, user_id: str = Depends(current_user_id)):
    with _open_artifact_zip(artifact_id, user_id) as (archive, info):
        entry = _zip_entry(archive, index)
        size = entry.file_size
        path = info["path"]

    def chunks():
        with ZipFile(path) as archive:
            with archive.open(_zip_entry(archive, index)) as file:
                while data := file.read(64 * 1024):
                    yield data

    return StreamingResponse(
        chunks(),
        media_type="application/octet-stream",
        headers={**_PRIVATE_RESPONSE, "Content-Length": str(size),
                 "Content-Disposition": "attachment"},
    )
