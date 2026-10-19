"""Endpoints para referências de mídia privadas com URL HMAC temporária."""
from __future__ import annotations

import mimetypes
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse

from ..core.document_builder.store import ArtifactStorageLimitError, load_artifact, save_artifact
from ..core.identity import current_user_id
from ..core.media_links import create_media_reference_url, validate_media_reference
from ._upload import read_upload_limited

router = APIRouter(prefix="/media", tags=["media"])
public_router = APIRouter(tags=["media-public"])


@router.post("/videos")
async def upload_video(
    file: UploadFile = File(...),
    user_id: str = Depends(current_user_id),
):
    """Guarda vídeo anexado para análise/edição e devolve o ID usado pelo chat."""
    filename = Path(file.filename or "video.mp4").name
    suffix = Path(filename).suffix.lower()
    if suffix not in {".mp4", ".m4v", ".mov", ".webm", ".mkv"}:
        raise HTTPException(415, "Formato de vídeo não suportado. Use MP4, MOV, WebM ou MKV.")
    try:
        data = await read_upload_limited(file, limit=50 * 1024 * 1024)
    finally:
        await file.close()
    if len(data) < 128:
        raise HTTPException(400, "O arquivo de vídeo está vazio ou incompleto.")
    mime = file.content_type or mimetypes.guess_type(filename)[0] or "video/mp4"
    try:
        saved = save_artifact(
            kind="video", filename=filename, data=data, user_id=user_id,
            meta={"mime": mime},
        )
    except ArtifactStorageLimitError as exc:
        raise HTTPException(413, str(exc)) from exc
    return {"ok": True, "artifact_id": saved["artifact_id"], "filename": saved["filename"], "size": saved["size"], "mime": mime}


def _is_reference_media(info: dict) -> bool:
    kind = str(info.get("kind", "")).lower()
    mime = str(info.get("mime") or info.get("content_type") or "").lower()
    filename = str(info.get("filename") or "").lower()
    guessed = mimetypes.guess_type(filename)[0] or ""
    return kind in {"image", "video", "media", "reference_media"} or mime.startswith(("image/", "video/")) or guessed.startswith(("image/", "video/"))


@router.get("/reference/{artifact_id}/url")
async def create_reference_url(
    artifact_id: str,
    user_id: str = Depends(current_user_id),
):
    info = load_artifact(artifact_id, user_id=user_id)
    if not info:
        raise HTTPException(status_code=404, detail="Mídia não encontrada ou expirada")
    if not _is_reference_media(info):
        raise HTTPException(status_code=415, detail="O arquivo não é uma imagem ou vídeo de referência")
    try:
        url = create_media_reference_url(artifact_id, user_id)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {"url": url, "expires_in": 1800}


@public_router.get("/media/reference/{artifact_id}")
async def serve_reference_media(
    artifact_id: str,
    expires: int = Query(...),
    signature: str = Query(..., min_length=32, max_length=128),
    owner: str = Query(..., min_length=1, max_length=128),
):
    if not validate_media_reference(artifact_id, expires, signature, owner):
        raise HTTPException(status_code=403, detail="Link de mídia inválido ou expirado")
    info = load_artifact(artifact_id, user_id=owner)
    if not info:
        raise HTTPException(status_code=404, detail="Mídia não encontrada ou expirada")
    if not _is_reference_media(info):
        raise HTTPException(status_code=415, detail="O arquivo não é uma imagem ou vídeo de referência")

    path = Path(str(info.get("path", ""))).resolve()
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Arquivo de mídia não encontrado")
    mime = str(info.get("mime") or info.get("content_type") or mimetypes.guess_type(path.name)[0] or "application/octet-stream")
    return FileResponse(path, media_type=mime, filename=path.name)
