"""Extração segura de ZIP para o Code Analyzer da Gamma.

O ZIP é lido uma única vez na ingestão. A análise profunda é acionada depois,
quando o usuário pede uma revisão/correção do projeto.
"""

from __future__ import annotations

import io
import logging
import zipfile
from pathlib import Path, PurePosixPath

from .cleaner import should_skip_dir, should_skip_file

logger = logging.getLogger(__name__)

# Limite para o arquivo enviado (comprimido). A hospedagem/proxy também precisa
# aceitar esse tamanho; este limite sozinho não altera limites externos.
MAX_ZIP_BYTES = 100 * 1024 * 1024  # 100 MiB
MAX_FILES = 30_000
MAX_SINGLE_FILE = 25 * 1024 * 1024  # evita arquivos binários enormes
MAX_TOTAL_UNCOMPRESSED = 1024 * 1024 * 1024  # proteção contra ZIP bombs


def safe_extract(zip_bytes: bytes, dest: Path) -> int:
    """Extrai arquivos úteis do ZIP sem traversal e sem expandir caches comuns.

    Arquivos/pastas gerados (venv, .git, build, node_modules etc.) são ignorados
    porque não são código-fonte necessário para revisar o projeto. O índice
    continua sendo construído a partir de todos os arquivos úteis extraídos.
    """
    if len(zip_bytes) > MAX_ZIP_BYTES:
        raise ValueError("ZIP maior que 100 MiB; compacte/remova caches ou envie um ZIP menor")

    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    total_uncompressed = 0

    try:
        archive = zipfile.ZipFile(io.BytesIO(zip_bytes))
    except (zipfile.BadZipFile, OSError) as exc:
        raise ValueError("O arquivo enviado não é um ZIP válido") from exc

    with archive as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if count >= MAX_FILES:
                raise ValueError(
                    f"O ZIP contém mais de {MAX_FILES} arquivos extraíveis; remova caches e dependências geradas"
                )

            normalized = info.filename.replace("\\", "/")
            rel = PurePosixPath(normalized)
            if rel.is_absolute() or not rel.parts or any(part in ("..", "") for part in rel.parts):
                logger.warning("ZIP: caminho inseguro ignorado: %r", info.filename)
                continue

            # Ignora dependências, caches e artefatos que não ajudam a revisar
            # o código e podem multiplicar muito o tamanho extraído.
            if any(should_skip_dir(part) for part in rel.parts[:-1]):
                continue
            relative_path = Path(*rel.parts)
            if should_skip_file(relative_path):
                continue

            # ZIP symlink entries não devem ser gravadas como arquivos normais.
            unix_mode = (info.external_attr >> 16) & 0o170000
            if unix_mode == 0o120000:
                continue
            if info.file_size > MAX_SINGLE_FILE:
                logger.warning("ZIP: arquivo individual grande ignorado (%s bytes): %s", info.file_size, rel)
                continue
            total_uncompressed += info.file_size
            if total_uncompressed > MAX_TOTAL_UNCOMPRESSED:
                raise ValueError("O conteúdo descompactado excede 1 GiB; ZIP recusado por segurança")

            target = dest.joinpath(*rel.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                with zf.open(info) as source, target.open("wb") as output:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                count += 1
            except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
                logger.warning("ZIP: falha ao extrair %s: %s", rel, exc)
                try:
                    target.unlink(missing_ok=True)
                except OSError:
                    pass

    return count
