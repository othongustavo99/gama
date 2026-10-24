"""Endpoints para referências de mídia privadas com URL HMAC temporária."""
from __future__ import annotations

import mimetypes
import asyncio
from urllib.parse import urlparse
import httpx
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse

from ..core.document_builder.store import ArtifactStorageLimitError, load_artifact, save_artifact
from ..core.identity import current_user_id
from ..core.media_links import create_media_reference_url, validate_media_reference
from ..core.video_jobs import get_job, list_jobs, public_job, update_job
from ..core.net_safety import safe_get, UnsafeURLError
from ..config import settings
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


@router.get("/video-jobs")
async def video_jobs_list(user_id: str = Depends(current_user_id)):
    """Jobs persistidos por usuário; útil após trocar de tela ou reiniciar app."""
    return {"ok": True, "jobs": list_jobs(user_id)}


@router.get("/video-jobs/{job_id}")
async def video_job_detail(job_id: str, user_id: str = Depends(current_user_id)):
    item = get_job(user_id, job_id)
    if item is None:
        raise HTTPException(404, "Trabalho não encontrado")
    return {"ok": True, "job": public_job(item)}


# Evita que duas chamadas de retomada iniciem downloads simultâneos neste
# processo. O store também mantém o artefato concluído no Volume.
_VIDEO_RESUME_LOCKS: dict[str, asyncio.Lock] = {}


@router.post("/video-jobs/{job_id}/resume")
async def resume_video_job(job_id: str, user_id: str = Depends(current_user_id)):
    """Consulta job existente na OpenRouter. Nunca inicia nova geração paga."""
    item = get_job(user_id, job_id)
    if item is None:
        raise HTTPException(404, "Trabalho não encontrado")
    lock_key = f"{user_id}:{job_id}"
    lock = _VIDEO_RESUME_LOCKS.setdefault(lock_key, asyncio.Lock())
    async with lock:
        item = get_job(user_id, job_id)
        if item is None:
            raise HTTPException(404, "Trabalho não encontrado")
        if item.get("status") == "completed":
            return {"ok": True, "job": public_job(item)}
        url = str(item.get("polling_url") or "")
        base = str(getattr(settings, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")).rstrip("/")
        pu, pb = urlparse(url), urlparse(base)
        if not (pu.scheme == pb.scheme == "https" and
                pu.netloc == pb.netloc and
                pu.path.startswith(pb.path.rstrip("/") + "/videos/") and
                not pu.username and not pu.password):
            raise HTTPException(409, "O trabalho ainda não possui uma referência segura no provedor")
        key = getattr(settings, "OPENROUTER_API_KEY", "")
        if not key:
            raise HTTPException(503, "Chave da OpenRouter não configurada")
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(40, connect=15), follow_redirects=False) as client:
                response = await client.get(url, headers={"Authorization": f"Bearer {key}"})
                if response.status_code != 200:
                    raise HTTPException(502, f"Falha na consulta do provedor (HTTP {response.status_code})")
                data = response.json()
                state = str(data.get("status", "")).lower()
                if state == "failed":
                    item = update_job(user_id, job_id, status="failed", phase="failed",
                                      error="A geração falhou no provedor")
                elif state != "completed":
                    item = update_job(user_id, job_id, status="processing", phase="video_generating")
                else:
                    links = data.get("unsigned_urls") or []
                    if isinstance(links, str):
                        links = [links]
                    source = next((s for s in links if isinstance(s, str) and s.startswith("https://")), None)
                    if source is None:
                        raise HTTPException(502, "Vídeo concluído, mas sem link de arquivo válido")
                    final_url, status, mime, content = await safe_get(
                        client, source, max_bytes=100 * 1024 * 1024, max_redirects=3)
                    if len(content) >= 100 * 1024 * 1024:
                        raise HTTPException(413, "O vídeo excedeu 100 MB; não vou salvar um arquivo incompleto")
                    if status != 200 or len(content) < 128 or not (
                        content[4:8] == b"ftyp" or content.startswith(b"\x1aE\xdf\xa3")
                    ):
                        raise HTTPException(502, "Arquivo retornado pelo provedor é inválido")
                    completed = get_job(user_id, job_id)
                    if completed and completed.get("status") == "completed":
                        return {"ok": True, "job": public_job(completed)}
                    from ..core.document_builder.store import save_artifact
                    saved = save_artifact(kind="video", filename="gama_video_gerado.mp4",
                        data=content, user_id=user_id,
                        meta={"model": item.get("model"), "recovered_job_id": job_id})
                    item = update_job(user_id, job_id, status="completed", phase="completed",
                                      artifact_id=saved["artifact_id"], filename=saved["filename"], error="")
        except HTTPException:
            raise
        except (httpx.HTTPError, UnsafeURLError, ValueError, OSError) as exc:
            raise HTTPException(503, "Não consegui retomar agora. Você pode tentar novamente sem gerar outro vídeo.") from exc
        return {"ok": True, "job": public_job(item)}
