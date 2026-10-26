"""Leitura de uploads limitada por configuração central do backend."""

from __future__ import annotations

from fastapi import HTTPException, UploadFile

from ..config import settings

MAX_UPLOAD_BYTES = settings.MAX_UPLOAD_MB * 1024 * 1024
_CHUNK = 1024 * 1024


async def read_upload_limited(file: UploadFile, limit: int | None = None) -> bytes:
    """Lê um arquivo em blocos e recusa assim que ultrapassar o limite efetivo."""
    effective_limit = MAX_UPLOAD_BYTES if limit is None else max(1, int(limit))
    # Starlette preenche size após o parsing multipart. Economiza a cópia em
    # memória quando o anexo já excede o máximo permitido.
    if getattr(file, "size", None) is not None and file.size > effective_limit:
        raise HTTPException(413, f"Arquivo maior que {effective_limit // (1024 * 1024)} MB")
    buf = bytearray()
    while True:
        chunk = await file.read(_CHUNK)
        if not chunk:
            break
        if len(buf) + len(chunk) > effective_limit:
            raise HTTPException(
                413,
                f"Arquivo maior que {effective_limit // (1024 * 1024)} MB",
            )
        buf.extend(chunk)
    return bytes(buf)
