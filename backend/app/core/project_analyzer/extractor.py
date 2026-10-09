"""Descompacta ZIP em diretório seguro."""

from __future__ import annotations

import io
import logging
import zipfile
from pathlib import Path

logger = logging.getLogger(__name__)

MAX_ZIP_BYTES = 80 * 1024 * 1024  # 80 MB
MAX_FILES = 8000
MAX_SINGLE_FILE = 5 * 1024 * 1024  # 5 MB por arquivo no extract


def safe_extract(zip_bytes: bytes, dest: Path) -> int:
    if len(zip_bytes) > MAX_ZIP_BYTES:
        raise ValueError(f"ZIP maior que {MAX_ZIP_BYTES // (1024*1024)} MB")

    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if count >= MAX_FILES:
                logger.warning("ZIP: limite de arquivos atingido")
                break
            # path traversal
            name = info.filename.replace("\\", "/")
            if name.startswith("/") or ".." in name.split("/"):
                continue
            if info.file_size > MAX_SINGLE_FILE:
                continue
            target = dest / name
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                with zf.open(info) as src, open(target, "wb") as out:
                    out.write(src.read())
                count += 1
            except Exception as e:
                logger.debug("skip %s: %s", name, e)
    return count
