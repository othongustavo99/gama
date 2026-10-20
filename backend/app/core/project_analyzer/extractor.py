"""Descompacta ZIP em diretório seguro (alinhado com code_analyzer)."""

from __future__ import annotations

import io
import logging
import zipfile
from pathlib import Path, PurePosixPath

from ..code_analyzer.cleaner import is_sensitive_file

logger = logging.getLogger(__name__)

MAX_ZIP_BYTES = 200 * 1024 * 1024  # alinhado com MAX_UPLOAD_MB do backend
MAX_FILES = 15_000
MAX_SINGLE_FILE = 15 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = 512 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
MAX_PATH_DEPTH = 40


def safe_extract(zip_bytes: bytes, dest: Path) -> int:
    if len(zip_bytes) > MAX_ZIP_BYTES:
        raise ValueError(f"ZIP maior que {MAX_ZIP_BYTES // (1024*1024)} MB")

    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    total = 0

    try:
        zf = zipfile.ZipFile(io.BytesIO(zip_bytes))
    except (zipfile.BadZipFile, OSError) as e:
        raise ValueError("ZIP inválido") from e

    with zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if count >= MAX_FILES:
                logger.warning("ZIP: limite de arquivos atingido")
                break

            name = info.filename.replace("\\", "/")
            # Não grave credenciais no workspace indexado nem as exponha ao modelo.
            if is_sensitive_file(name):
                logger.warning("ZIP: arquivo sensível ignorado na ingestão: %r", name)
                continue
            rel = PurePosixPath(name)
            if rel.is_absolute() or any(p in ("..", "") for p in rel.parts):
                continue
            if len(rel.parts) > MAX_PATH_DEPTH:
                continue
            if info.file_size > MAX_SINGLE_FILE:
                continue
            if info.compress_size > 0 and info.file_size / max(info.compress_size, 1) > MAX_COMPRESSION_RATIO:
                continue

            total += info.file_size
            if total > MAX_TOTAL_UNCOMPRESSED:
                raise ValueError("Conteúdo descompactado excede limite de segurança")

            target = dest / name
            try:
                target.resolve().relative_to(dest.resolve())
            except ValueError:
                continue

            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                with zf.open(info) as src, open(target, "wb") as out:
                    while True:
                        chunk = src.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
                count += 1
            except Exception as e:
                logger.debug("skip %s: %s", name, e)
    return count
