"""Leitura de uploads com teto de tamanho (evita carregar arquivos gigantes na memória)."""

from __future__ import annotations

from fastapi import HTTPException, UploadFile

MAX_UPLOAD_BYTES = 100 * 1024 * 1024
_CHUNK = 1024 * 1024


async def read_upload_limited(file: UploadFile, limit: int = MAX_UPLOAD_BYTES) -> bytes:
    buf = bytearray()
    while True:
        chunk = await file.read(_CHUNK)
        if not chunk:
            break
        buf.extend(chunk)
        if len(buf) > limit:
            raise HTTPException(413, f"Arquivo maior que {limit // (1024 * 1024)} MB")
    return bytes(buf)
